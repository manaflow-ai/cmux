public import AppKit
public import CmuxNextActions
public import CmuxNextDevices
import CmuxScreenKit
import Foundation
public import Observation
import os

/// This Mac as a device hub host: "Allow Mac Screen on this Mac" (the hub's
/// `mac_screen_shared`), and the sessions the hub approves. Each
/// `session.ticket` for the host role is served by its own
/// `ScreenStreamHost` (View Only sessions pass no input) over the ticket's
/// signaling; a revocation or end closes it at once. One session at a time:
/// a newer one replaces the older. Permissions (Screen Recording,
/// Accessibility) are checked by `MacScreenShareHost`.
@MainActor @Observable
public final class MacScreenHubHost {
    /// The session this Mac serves now.
    public struct Session: Equatable, Sendable {
        public var id: String
        public var viewerID: String
        public var viewerName: String
        public var scope: SessionScope
        /// The viewer's data channel opened: it sees (and, Full Control, controls) the screen.
        public var connected: Bool
    }

    public private(set) var session: Session?
    /// Turning sharing on or off is in flight.
    public private(set) var busy = false
    public private(set) var lastError: String?

    @ObservationIgnored var hub: @MainActor () -> DeviceHub? = { nil }
    @ObservationIgnored public let share: MacScreenShareHost
    @ObservationIgnored private var host: ScreenStreamHost?
    @ObservationIgnored private var serveTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let indicator = MacScreenShareIndicator()
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-hub-host")
    /// Makes the host for one session; tests replace it.
    @ObservationIgnored var makeHost: (_ name: String, _ viewOnly: Bool) -> ScreenStreamHost = { name, viewOnly in
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-hub-host")
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        return ScreenStreamHost(name: name, viewOnly: viewOnly, backend: { ScreenCaptureBackend(log: log) }, log: log)
    }
    /// The hub calls the host's controls make; tests replace them.
    @ObservationIgnored var endSession: @MainActor (DeviceHub, String, String) async -> Void = { hub, id, reason in
        try? await hub.endSession(id, reason: reason)
    }
    @ObservationIgnored var revokePermission: @MainActor (DeviceHub, String) async throws -> Void = { hub, viewer in
        try await hub.setPermission(host: hub.identity.id, viewer: viewer, scope: .none)
    }
    /// Makes a session's signaling from its ticket; tests replace it.
    @ObservationIgnored var makeSignaling: @MainActor (SessionTicket, DeviceHub) throws -> any ScreenSignaling = MacScreenHubViewer.ticketSignaling

    init(share: MacScreenShareHost) {
        self.share = share
    }

    /// Whether this Mac allows Mac Screen (the hub's record of this device).
    public var isSharing: Bool { hub()?.thisDevice?.macScreenShared ?? false }

    /// The person's switch: asks for Screen Recording (and Accessibility)
    /// when turning on, and tells the hub. Off ends a running session (the
    /// hub revokes it too).
    public func setSharing(_ on: Bool) async throws {
        guard let hub = hub() else { throw DeviceHubError.notSignedIn }
        if on {
            await share.refreshPermissions()
            if !share.screenRecordingGranted {
                share.requestScreenRecording()
            } else if !share.accessibilityGranted {
                share.requestAccessibility()
            }
        }
        busy = true
        defer { busy = false }
        do {
            try await hub.setMacScreenShared(on)
            lastError = nil
        } catch {
            lastError = (error as? DeviceHubError)?.description ?? "\(error)"
            throw error
        }
        if !on { closeLocal() }
    }

    // MARK: Pushes

    /// `session.ticket` for the host role: serve it.
    func serve(_ ticket: SessionTicket) {
        guard ticket.role == .host, let hub = hub() else { return }
        if let current = session, current.id != ticket.sessionId {
            // One viewer at a time: the newer session wins.
            closeLocal()
            end(current.id, reason: .replaced, hub: hub)
        }
        let signaling: any ScreenSignaling
        do { signaling = try makeSignaling(ticket, hub) } catch {
            logger.error("session ticket refused: \(String(describing: error), privacy: .public)")
            end(ticket.sessionId, reason: .failed, hub: hub)
            return
        }
        let host = makeHost(MacScreenShareHost.computerName, ticket.scope == .view)
        let (events, sink) = AsyncStream.makeStream(of: ScreenStreamHost.Event.self, bufferingPolicy: .bufferingNewest(64))
        host.onEvent = { event in sink.yield(event) }
        self.host = host
        session = Session(id: ticket.sessionId, viewerID: ticket.peer.id, viewerName: ticket.peer.name, scope: ticket.scope,
                          connected: false)
        let id = ticket.sessionId
        eventTask = Task { [weak self, weak host] in
            for await event in events {
                guard let self, let host, self.host === host else { return }
                handle(event, session: id)
            }
        }
        serveTask = Task.detached { [weak self] in
            try? await host.serve(signaling)
            await self?.served(host, session: id)
        }
        logger.info("serving a device hub session (\(ticket.scope.rawValue, privacy: .public))")
    }

    /// `session.revoked` or `session.ended`: the session ends now.
    func sessionOver(_ id: String) {
        guard session?.id == id else { return }
        closeLocal()
    }

    private func handle(_ event: ScreenStreamHost.Event, session id: String) {
        guard session?.id == id else { return }
        switch event {
        case .viewerConnected:
            session?.connected = true
            updateIndicator()
        case .viewerEnded:
            closeLocal()
        case let .sourceFailed(message):
            logger.error("screen capture failed: \(message, privacy: .public)")
            stopSession(reason: .failed)
        case .waiting, .roomLost:
            break
        }
    }

    /// The host's serve loop returned (bye, closed, revoked).
    /// A connected session outlives its signaling (a dropped hub link): the
    /// viewer leaving, the hub's revocation or end, or Stop Sharing ends it.
    private func served(_ host: ScreenStreamHost, session id: String) {
        guard self.host === host, let current = session, current.id == id, !current.connected else { return }
        closeLocal()
    }

    // MARK: The person's controls

    /// Stop Sharing (menu bar, Mac Screen home): the hub hears `host_stopped`
    /// first (`/end`), then the stream closes, so the viewer reads why.
    /// `immediately` (quitting) closes at once.
    @discardableResult
    public func stopSession(reason: MacScreenHubReason = .hostStopped, immediately: Bool = false) -> Task<Void, Never>? {
        guard let current = session else { return nil }
        guard let hub = hub(), !immediately else {
            closeLocal()
            if let hub = hub() { end(current.id, reason: reason, hub: hub) }
            return nil
        }
        let end = endSession
        // task-owner: one /end, then this session's stream closes (its revocation push may close it first)
        return Task { [weak self] in
            await end(hub, current.id, reason.rawValue)
            guard let self, session?.id == current.id else { return }
            closeLocal()
        }
    }

    /// Revoke This Device: this Mac (the host, the only device that may)
    /// sets its access to None. The hub revokes the session with that reason
    /// and pushes it to both Macs, which closes it here (`sessionOver`). Only
    /// when the write fails does it end the session itself.
    @discardableResult
    public func revokeViewer() -> Task<Void, Never>? {
        guard let current = session, let hub = hub() else { return nil }
        let revoke = revokePermission
        // task-owner: one permission write; the hub's revocation push closes the session
        return Task { [weak self] in
            do { try await revoke(hub, current.viewerID) } catch {
                await self?.stopSession(reason: .hostStopped)?.value
            }
        }
    }

    /// Signed out, or the hub went away: end the session here (the caller told the hub first, when it could).
    func closeAll() {
        closeLocal()
    }

    private func closeLocal() {
        let host = self.host
        self.host = nil
        host?.onEvent = nil
        // Closing the peer connection waits on WebRTC's threads: never on the main actor.
        if let host { Task.detached { host.disconnectViewer() } }
        serveTask = nil
        eventTask?.cancel()
        eventTask = nil
        session = nil
        updateIndicator()
    }

    private func end(_ id: String, reason: MacScreenHubReason, hub: DeviceHub) {
        // task-owner: one /end call; the hub pushes the end to both Macs
        Task { try? await hub.endSession(id, reason: reason.rawValue) }
    }

    private func updateIndicator() {
        guard let session, session.connected else {
            indicator.setVisible(false)
            return
        }
        let title = session.scope == .view
            ? String(format: L.t("macScreen.indicator.viewing", "%@ is viewing this Mac"), session.viewerName)
            : String(format: L.t("macScreen.indicator.controlling", "%@ is controlling this Mac"), session.viewerName)
        indicator.setVisible(true)
        indicator.update(title: title, offersRevoke: true)
    }

    /// Why Stop Sharing This Mac and Revoke This Device cannot run: nil while a device is connected.
    public var noSessionReason: String? {
        session == nil ? L.t("macScreen.indicator.noSession", "No device is viewing or controlling this Mac.") : nil
    }

    /// The menu bar item's rows: the registry's items for its actions (the app sets this).
    public var indicatorMenuItem: (ActionID) -> NSMenuItem? {
        get { indicator.menuItem }
        set { indicator.menuItem = newValue }
    }

    /// The menu bar item's state, for `debug.device_hub`.
    var indicatorTitle: String? { session?.connected == true ? indicator.title : nil }
}
