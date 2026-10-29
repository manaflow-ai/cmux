#if os(iOS)
public import CmuxDeviceHub
public import Foundation
public import Observation

/// This iPhone as a device of the device hub (docs/device-hub/PROTOCOL.md),
/// for Screen Sharing: it registers the phone (platform `ios`), keeps the User
/// DO socket open, lists the account's Macs and routes the hub's session
/// pushes to the viewer on screen. The Macs stay the hosts: they approve,
/// stream and enforce the scope; the phone only views and sends input.
@MainActor @Observable
public final class ScreenSharingService {
    public enum Status: Equatable, Sendable {
        /// Not started (signed out, or never opened).
        case idle
        case starting
        case ready
        case failed(String)
    }

    public private(set) var status: Status = .idle
    /// The hub, once this phone's identity loaded (nil before and after sign-out).
    public private(set) var hub: DeviceHub?
    /// The viewer on screen: one session at a time from this phone.
    public private(set) var viewer: ScreenSharingViewer?
    /// The person's viewer choices (input mode, quality, stats), kept on this phone.
    public let preferences: ScreenSharingPreferences

    @ObservationIgnored let configuration: Configuration
    /// Runs on each new viewer before its first request (tests swap its hub calls).
    @ObservationIgnored var prepareViewer: (ScreenSharingViewer) -> Void = { _ in }
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Where the hub is and who this phone is to it.
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var bundleIdentifier: String
        public var deviceName: String
        public var tokens: any DeviceHubAccountTokenProvider

        public init(baseURL: URL, bundleIdentifier: String, deviceName: String, tokens: any DeviceHubAccountTokenProvider) {
            self.baseURL = baseURL
            self.bundleIdentifier = bundleIdentifier
            self.deviceName = deviceName
            self.tokens = tokens
        }
    }

    /// The dev hub accepts the Stack development project DEBUG builds sign in to; every other build uses production.
    public static let developmentHubURL = URL(string: "https://cmux-device-hub-dev.debussy.workers.dev")!
    public static let productionHubURL = URL(string: "https://cmux-device-hub.debussy.workers.dev")!

    /// The hub a build uses: DEBUG builds the dev hub (or `CMUX_MOBILE_DEVICE_HUB_URL`), others production.
    public static func hubURL(isDebug: Bool, environment: [String: String]) -> URL {
        guard isDebug else { return productionHubURL }
        if let text = environment["CMUX_MOBILE_DEVICE_HUB_URL"], let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
            return url
        }
        return developmentHubURL
    }

    public init(configuration: Configuration, preferences: ScreenSharingPreferences = ScreenSharingPreferences()) {
        self.configuration = configuration
        self.preferences = preferences
    }

    /// A hub built elsewhere (tests, previews): already loaded, not yet started.
    init(hub: DeviceHub, configuration: Configuration, preferences: ScreenSharingPreferences) {
        self.configuration = configuration
        self.preferences = preferences
        attach(hub)
    }

    /// The account's Macs, those sharing their screen and online first, then by name.
    public var macs: [HubDevice] {
        guard let hub else { return [] }
        return hub.otherDevices.filter { $0.platform == .macos }.sorted(by: Self.listOrder)
    }

    /// Sharing and online first, then online, then the rest; by name within each.
    nonisolated static func listOrder(_ lhs: HubDevice, _ rhs: HubDevice) -> Bool {
        let left = lhs.rank, right = rhs.rank
        return left != right ? left < right : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// What this phone may do on `mac`'s screen, as the Mac last listed it.
    public func access(to mac: HubDevice) -> DeviceScope {
        guard let hub else { return .ask }
        return hub.scope(host: mac.id, viewer: hub.identity.id)
    }

    // MARK: Lifecycle

    /// Opens the hub: loads this phone's identity (off the main thread),
    /// registers it and keeps the socket open. Calling it again while it runs does nothing.
    public func start() {
        switch status {
        case .starting, .ready: return
        case .idle, .failed: break
        }
        status = .starting
        let configuration = configuration
        startTask = Task { [weak self] in
            let hub: DeviceHub
            do {
                hub = try await DeviceHub.forApp(baseURL: configuration.baseURL, bundleIdentifier: configuration.bundleIdentifier,
                                                 deviceName: configuration.deviceName, platform: .ios, tokens: configuration.tokens)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed(String(describing: error))
                return
            }
            guard let self, !Task.isCancelled else { return }
            attach(hub)
            await hub.start()
            guard !Task.isCancelled else { return }
            status = Self.status(of: hub.status)
        }
    }

    /// Signed out: ends the session on screen, signs this phone out of the hub and forgets it.
    public func stop() {
        startTask?.cancel()
        startTask = nil
        viewer?.close(reason: .signedOut)
        viewer = nil
        if let hub {
            hub.onSessionPush = nil
            // task-owner: one sign-out call (the hub lists this phone offline at once), then the socket closes
            Task {
                try? await hub.signOutDevice()
                hub.stop()
            }
        }
        hub = nil
        status = .idle
    }

    /// Refetches everything (pull to refresh).
    public func refresh() async {
        guard let hub else { return start() }
        if case .failed = status { await hub.start() } else { await hub.refreshAll() }
        status = Self.status(of: hub.status)
    }

    private func attach(_ hub: DeviceHub) {
        self.hub = hub
        hub.onSessionPush = { [weak self] push in self?.route(push) }
    }

    static func status(of status: DeviceHub.Status) -> Status {
        switch status {
        case .idle: .idle
        case .starting: .starting
        case .ready: .ready
        case let .failed(message): .failed(message)
        }
    }

    // MARK: Sessions

    /// Asks `mac` for a session and puts its viewer on screen.
    @discardableResult
    public func connect(to mac: HubDevice, scope: SessionScope) -> ScreenSharingViewer? {
        guard let hub else { return nil }
        let viewer: ScreenSharingViewer
        if let current = self.viewer, current.hostID == mac.id {
            viewer = current
        } else {
            self.viewer?.close(reason: .viewerDisconnected)
            viewer = ScreenSharingViewer(hostID: mac.id, hostName: mac.name, hub: hub, preferences: preferences)
            prepareViewer(viewer)
            self.viewer = viewer
        }
        viewer.request(scope)
        return viewer
    }

    /// The viewer went away (closed by the person): the session ends on both sides.
    public func dismissViewer() {
        viewer?.close(reason: .viewerDisconnected)
        viewer = nil
    }

    /// A `session.*` push: the viewer on screen takes the ones about its session.
    func route(_ push: DeviceHubPush) {
        guard let viewer else { return }
        switch push {
        case let .sessionTicket(ticket) where viewer.accepts(ticket): viewer.accept(ticket)
        case let .sessionDenied(id) where viewer.sessionID == id: viewer.denied()
        case let .sessionRevoked(id, reason) where viewer.sessionID == id: viewer.ended(reason: reason)
        case let .sessionEnded(id, reason) where viewer.sessionID == id: viewer.ended(reason: reason)
        default: break
        }
    }
}

extension HubDevice {
    /// Sharing and online first, then online, then the rest.
    fileprivate var rank: Int { macScreenShared && online ? 0 : online ? 1 : 2 }
}
#endif
