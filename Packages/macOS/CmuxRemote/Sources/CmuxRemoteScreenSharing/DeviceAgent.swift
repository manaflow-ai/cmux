// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxDeviceHub
import CmuxRemoteWire
import CryptoKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "device-agent")

/// What the worker keeps between launches (`screen-sharing.json`, 0600): the
/// account and hub its device was anchored to, and this Mac's local consent
/// for Mac Screen as the app last told it.
struct ScreenSharingState: Codable, Equatable, Sendable {
    var userID: String?
    var hubURL: String?
    /// The app has told this worker its join consent at least once; until then no session serves.
    var consentKnown = false
    /// The app's join consent: when `enabled`, a session needs `view` (or `full` for Full Control).
    var consentEnabled = false
    var consentView = true
    var consentFull = true

    static func load(_ path: String) -> ScreenSharingState {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? ScreenSharingState()
    }

    func save(_ path: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let temporary = path + ".tmp"
        FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600])
        _ = rename(temporary, path)
    }

    func permits(_ scope: SessionScope) -> Bool {
        guard consentKnown else { return false }
        guard consentEnabled else { return true }
        return scope == .full ? consentFull : consentView
    }
}

/// This Mac on the device hub, from cmux Remote (docs/cmux-remote.md, Screen
/// Sharing worker): its Secure Enclave keys, its one User DO socket, the
/// approval banner, the menu bar indicator and the sessions. Its account
/// session is device-key renewal (`POST /v1/auth/device`), so it serves with
/// the cmux app quit; the signed-in app anchors it and signs its own hub
/// requests with this device's keys, so this Mac is one device.
@MainActor
final class DeviceAgent {
    let keychainScope: String
    let statePath: String
    let headless: Bool
    private(set) var identity: DeviceIdentity?
    private(set) var hub: DeviceHub?
    private(set) var state: ScreenSharingState
    let sessions = HostSessions()
    let banner = ApprovalBanner()
    let indicator = ShareIndicator()
    /// Pushes and socket states, as raw lines, for the app's subscriptions.
    let relay = PushRelay()
    /// Called when anything in `status` changes.
    var changed: () -> Void = {}
    private var loading: Task<DeviceIdentity?, Never>?

    init(keychainScope: String, statePath: String, headless: Bool) {
        self.keychainScope = keychainScope
        self.statePath = statePath
        self.headless = headless
        state = ScreenSharingState.load(statePath)
        sessions.hub = { [weak self] in self?.hub }
        sessions.permits = { [weak self] in self?.state.permits($0) ?? false }
        sessions.changed = { [weak self] in self?.sessionsChanged() }
        banner.changed = { [weak self] in self?.changed() }
        banner.decide = { [weak self] request, choice in
            guard let hub = self?.hub else { throw DeviceHubError.notSignedIn }
            let (decision, scope, thenPermission) = choice.answer(requested: request.scope)
            try await hub.decide(request, decision: decision, scope: scope)
            if let thenPermission { try await hub.setPermission(host: hub.identity.id, viewer: request.viewerId, scope: thenPermission) }
        }
        indicator.stop = { [weak self] in self?.sessions.stop() }
        indicator.revoke = { [weak self] in self?.sessions.revokeViewer() }
    }

    /// This device's identity, loaded off the main thread once (the file
    /// Keychain and Secure Enclave can take seconds).
    func loadIdentity() async -> DeviceIdentity? {
        if let identity { return identity }
        let task = loading ?? Task.detached { [keychainScope] in
            do { return try DeviceIdentity.forApp(bundleIdentifier: keychainScope) } catch {
                logger.error("device identity: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        loading = task
        identity = await task.value
        return identity
    }

    /// At launch: joins the hub when an anchor was recorded.
    func start() async {
        _ = await loadIdentity()
        startHub()
    }

    // MARK: Account

    /// The app anchored this device for `userID` on `hubURL`.
    func anchored(userID: String, hubURL: String) {
        let changedAccount = state.userID != userID || state.hubURL != hubURL
        state.userID = userID
        state.hubURL = hubURL
        state.save(statePath)
        if changedAccount || hub == nil { startHub() }
    }

    /// The app signed out: this device leaves the hub until it anchors again.
    func signedOut() {
        state.userID = nil
        state.save(statePath)
        stopHub()
    }

    func setConsent(enabled: Bool, view: Bool, full: Bool) {
        state.consentKnown = true
        state.consentEnabled = enabled
        state.consentView = view
        state.consentFull = full
        state.save(statePath)
        sessions.consentChanged()
    }

    /// The hub refused this identity (removed): a new one; the app registers it.
    func renewIdentity() async -> DeviceIdentity? {
        stopHub()
        let fresh = await Task.detached { [keychainScope] in try? DeviceIdentity.renew(bundleIdentifier: keychainScope) }.value
        if let fresh { identity = fresh }
        return fresh
    }

    private func startHub() {
        stopHub()
        guard let identity, let userID = state.userID, let text = state.hubURL, let url = URL(string: text) else { return }
        let client = DeviceHubClient(baseURL: url, identity: identity, source: .deviceRenewal(userID: userID))
        let relay = self.relay
        let socket = DeviceHubSocket(connector: RelayingConnector(inner: URLSessionDeviceHubConnector(client: client), relay: relay))
        let hub = DeviceHub(client: client, socket: socket, secrets: KeychainRelaySecretStore(bundleIdentifier: keychainScope),
                            deviceName: Host.current().localizedName ?? "Mac")
        hub.onSessionPush = { [weak self] push in self?.handle(push) }
        self.hub = hub
        followPending(hub)
        Task { [weak self] in
            await hub.start()
            self?.changed()
        }
        logger.notice("joined the device hub as \(identity.id, privacy: .public)")
        changed()
    }

    private func stopHub() {
        sessions.closeAll()
        hub?.onSessionPush = nil
        hub?.stop()
        hub = nil
        banner.update([])
        changed()
    }

    private func handle(_ push: DeviceHubPush) {
        switch push {
        case let .sessionTicket(ticket): sessions.serve(ticket)
        case let .sessionRevoked(id, _), let .sessionEnded(id, _): sessions.sessionOver(id)
        default: break
        }
        changed()
    }

    /// The banner follows the hub's pending requests (Observation, no poll).
    private func followPending(_ hub: DeviceHub) {
        let requests = withObservationTracking { hub.pendingRequests } onChange: { [weak self, weak hub] in
            Task { @MainActor [weak self, weak hub] in
                guard let self, let hub, self.hub === hub else { return }
                followPending(hub)
            }
        }
        banner.update(requests)
    }

    private func sessionsChanged() {
        indicator.show(sessions.indicatorTitle)
        changed()
    }

    // MARK: Controls

    /// Share This Mac off (a host session may; on needs the signed-in app, which asks the person).
    func shareOff() async -> Result<Bool, DeviceHubError> {
        guard let hub else { return .failure(.notSignedIn) }
        do {
            try await hub.setMacScreenShared(false)
            sessions.stop()
            return .success(false)
        } catch {
            return .failure(error as? DeviceHubError ?? .transport("\(error)"))
        }
    }

    /// A viewer's access on this Mac. A host session may only lower it (the hub enforces it too).
    func setAccess(viewer: String, scope: DeviceScope) async -> Result<DeviceScope, DeviceHubError> {
        guard let hub else { return .failure(.notSignedIn) }
        let order: [DeviceScope] = [.none, .ask, .view, .full]
        let current = hub.scope(host: hub.identity.id, viewer: viewer)
        guard (order.firstIndex(of: scope) ?? 3) < (order.firstIndex(of: current) ?? 0) || scope == .none else {
            return .failure(.server(status: 403, code: .other("host_scope"), message: "raising a device's access needs the cmux app"))
        }
        do {
            try await hub.setPermission(host: hub.identity.id, viewer: viewer, scope: scope)
            return .success(scope)
        } catch {
            return .failure(error as? DeviceHubError ?? .transport("\(error)"))
        }
    }

    // MARK: Status

    var status: [String: Any] {
        var fields: [String: Any] = ["signed_in": state.userID != nil, "headless": headless,
                                     "consent": ["enabled": state.consentEnabled, "view": state.consentView, "full": state.consentFull]]
        if let identity { fields["device_id"] = identity.id }
        if let hub {
            fields["hub"] = Self.describe(hub.status)
            fields["connection"] = Self.describe(hub.connection)
            fields["sharing"] = hub.thisDevice?.macScreenShared ?? false
            fields["devices"] = hub.otherDevices.map { device -> [String: Any] in
                ["id": device.id, "name": device.name, "platform": device.platform?.rawValue ?? "", "online": device.online,
                 "access": hub.scope(host: hub.identity.id, viewer: device.id).rawValue]
            }
        }
        if let session = sessions.session { fields["session"] = session.fields }
        if let request = banner.current {
            fields["pending"] = ["id": request.id, "viewer_name": request.viewerName, "scope": request.scope.rawValue]
        }
        if let frame = banner.frame { fields["banner"] = [frame.minX, frame.minY, frame.width, frame.height].map { Int($0) } }
        if !indicator.title.isEmpty { fields["indicator"] = indicator.title }
        return fields
    }

    static func describe(_ value: some Any) -> String { String(describing: value) }

}

/// The User DO socket's frames, fanned out to the app's subscriptions: the app's own hub
/// model (viewer pushes, device lists) reads the one socket this device may have. Each
/// subscriber has its own serial queue and at most `limit` frames waiting; one that falls that
/// far behind (an app that stopped reading) is dropped, so it never stalls the hub socket.
final class PushRelay: Sendable {
    private struct Subscriber: Sendable {
        let queue: DispatchQueue
        let pending: OSAllocatedUnfairLock<Int>
        let send: @Sendable (Data) -> Bool
    }

    static let limit = 256
    private let subscribers = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Subscriber]())

    func add(_ id: ObjectIdentifier, _ send: @escaping @Sendable (Data) -> Bool) {
        let subscriber = Subscriber(queue: DispatchQueue(label: "cmux-remote.push-relay", qos: .utility),
                                    pending: OSAllocatedUnfairLock(initialState: 0), send: send)
        subscribers.withLock { $0[id] = subscriber }
    }

    func remove(_ id: ObjectIdentifier) {
        subscribers.withLock { _ = $0.removeValue(forKey: id) }
    }

    var count: Int { subscribers.withLock { $0.count } }

    func publish(_ line: Data) {
        let all = subscribers.withLock { $0 }
        for (id, subscriber) in all {
            let queued = subscriber.pending.withLock { pending -> Bool in
                guard pending < Self.limit else { return false }
                pending += 1
                return true
            }
            guard queued else {
                remove(id)
                continue
            }
            subscriber.queue.async { [weak self] in
                subscriber.pending.withLock { $0 -= 1 }
                if !subscriber.send(line) { self?.remove(id) }
            }
        }
    }
}

/// The hub socket connector whose frames also reach `relay`.
struct RelayingConnector: DeviceHubSocketConnector {
    let inner: any DeviceHubSocketConnector
    let relay: PushRelay

    func connect() async throws -> any DeviceHubSocketConnection {
        let connection = try await inner.connect()
        relay.publish(RemoteWire.event("hub_state", ["state": "connected"]))
        return RelayingConnection(inner: connection, relay: relay)
    }
}

struct RelayingConnection: DeviceHubSocketConnection {
    let inner: any DeviceHubSocketConnection
    let relay: PushRelay

    func receive() async throws -> String {
        let text = try await inner.receive()
        relay.publish(RemoteWire.event("push", ["text": text]))
        return text
    }

    func send(_ text: String) async throws { try await inner.send(text) }
    func close() { inner.close() }
}
