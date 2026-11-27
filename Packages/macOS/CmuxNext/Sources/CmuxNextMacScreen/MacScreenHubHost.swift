public import AppKit
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDevices
import CmuxScreenKit
import Foundation
public import Observation
import os

/// This Mac as a device hub host: "Allow Mac Screen on this Mac" (the hub's
/// `mac_screen_shared`), and the sessions the hub approves. Each
/// `session.ticket` for the host role is served by its own
/// `MacScreenRdHost` (cmux.rd/1; View Only sessions apply no input) over the
/// ticket's signaling; a revocation or end closes it at once. One session at a time:
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
        /// The hub admitted it as the person's own device (``SessionTicket/isOwnAccount``): no consent here gates it.
        public var ownAccount = false
        /// The viewer's data channel opened: it sees (and, Full Control, controls) the screen.
        public var connected: Bool
    }

    public private(set) var session: Session?
    /// Turning sharing on or off is in flight.
    public private(set) var busy = false
    public private(set) var lastError: String?

    /// After a person's own switch of sharing (every `setSharing` caller is one; an owner's agent
    /// changes it on the hub directly): an agent's share stops counting down (`agent.person`).
    @ObservationIgnored var personChangedSharing: @MainActor () async -> Void = {}
    @ObservationIgnored var hub: @MainActor () -> DeviceHub? = { nil }
    @ObservationIgnored public let share: MacScreenShareHost
    @ObservationIgnored private var host: MacScreenRdHost?
    @ObservationIgnored private var serveTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let indicator = MacScreenShareIndicator()
    /// The menu bar item's line while an owner's agent's share is on (``showAgentShare(_:whenOff:)``).
    @ObservationIgnored private var agentShareTitle: String?
    @ObservationIgnored private var agentShareWatch: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-hub-host")
    /// Makes the host for one session; tests replace it.
    @ObservationIgnored var makeHost: (MacScreenRdHost.Session) -> MacScreenRdHost = { MacScreenRdHost(session: $0) }
    /// The hub calls the host's controls make; tests replace them.
    @ObservationIgnored var endSession: @MainActor (DeviceHub, String, String) async -> Void = { hub, id, reason in
        try? await hub.endSession(id, reason: reason)
    }
    @ObservationIgnored var revokePermission: @MainActor (DeviceHub, String) async throws -> Void = { hub, viewer in
        try await hub.setPermission(host: hub.identity.id, viewer: viewer, scope: .none)
    }
    /// Whether this Mac's local consent allows a session (the one-line join's gate, which acpmux cannot
    /// apply to Mac Screen since the app serves it), read when the ticket arrives; a refused ticket is
    /// ended unserved. Nil: every ticket serves at once.
    @ObservationIgnored public var consentGate: (@MainActor (SessionTicket) async -> Bool)?
    /// Makes a session's signaling from its ticket; tests replace it.
    @ObservationIgnored var makeSignaling: @MainActor (SessionTicket, DeviceHub) throws -> any ScreenSignaling = MacScreenHubViewer.ticketSignaling
    /// Writes this Mac's sharing bit to the hub; tests replace it.
    @ObservationIgnored var writeSharing: @MainActor (DeviceHub, Bool) async throws -> Void = { hub, on in
        try await hub.setMacScreenShared(on)
    }
    /// Whether the person turned sharing off on this Mac (MacScreenStore keeps it); nil until the
    /// store is read. The pages set it, and ``sharingChosen``, which keeps a person's switch.
    @ObservationIgnored var sharingTurnedOff: @MainActor () -> Bool? = { nil }
    @ObservationIgnored var sharingChosen: @MainActor (Bool) -> Void = { _ in }

    /// cmux-rd-core's host reducer for this Mac (`rd_hub_host_*`, keyed by this id) decides which
    /// ticket serves and how a session ends; this class mirrors its session and runs its effects.
    @ObservationIgnored private let rdID = UUID().uuidString

    init(share: MacScreenShareHost) {
        self.share = share
    }

    deinit { _ = MacScreenRules.rdHub("rd_hub_host_close", ["host": rdID]) }

    /// Whether this Mac allows Mac Screen (the hub's record of this device).
    public var isSharing: Bool { hub()?.thisDevice?.macScreenShared ?? false }

    /// The person's switch: asks for Screen Recording (and Accessibility)
    /// when turning on, and tells the hub. Off ends a running session (the
    /// hub revokes it too). `byPerson` (every caller but the default,
    /// MacScreenHubHost+DefaultSharing) keeps the choice: an off stays off.
    public func setSharing(_ on: Bool, requestPermissions: Bool = true, byPerson: Bool = true) async throws {
        guard let hub = hub() else { throw DeviceHubError.notSignedIn }
        if byPerson { sharingChosen(on) }
        if on && requestPermissions {
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
            try await writeSharing(hub, on)
            lastError = nil
        } catch {
            lastError = (error as? DeviceHubError)?.description ?? "\(error)"
            throw error
        }
        if !on { send(["event": "close_all"]) }
        await personChangedSharing()
    }

    // MARK: Pushes

    /// `session.ticket` for the host role: serve it once this Mac's consent allows it. A ticket the
    /// acpmux daemon's share host serves (its relay says `servedBy: "daemon"`) is the daemon's alone:
    /// no consent read, no host, no `/end` here, and it never becomes this app's ``session``. The
    /// person's own device serves at once (Leo, 2026-11-16, ask-da398bba67); others wait for consent.
    func serve(_ ticket: SessionTicket) {
        guard ticket.role == .host else { return }
        if ticket.isServedByDaemon { logger.info("session ticket served by the acpmux daemon") }
        send(["event": "serve", "ticket": ticket.rdHost, "consent_gate": consentGate != nil], ticket: ticket)
    }

    /// This Mac's consent changed: a session it no longer allows (its scope) stops now.
    public func consentChanged(allows: (SessionScope) -> Bool) {
        send(["event": "consent_changed", "allows": [SessionScope.view, .full].filter(allows).map(\.rawValue)])
    }

    /// `session.revoked` or `session.ended`: the session ends now.
    func sessionOver(_ id: String) { send(["event": "session_over", "session_id": id]) }

    // MARK: The person's controls

    /// Stop Sharing (menu bar, Mac Screen home): the hub hears `host_stopped`
    /// first (`/end`), then the stream closes, so the viewer reads why.
    /// `immediately` (quitting) closes at once.
    @discardableResult
    public func stopSession(reason: MacScreenHubReason = .hostStopped, immediately: Bool = false) -> Task<Void, Never>? {
        send(["event": "stop", "reason": reason.rawValue, "immediately": immediately])
    }

    /// Revoke This Device: this Mac (the host, the only device that may)
    /// sets its access to None. The hub revokes the session with that reason
    /// and pushes it to both Macs, which closes it here (`sessionOver`). Only
    /// when the write fails does it end the session itself.
    @discardableResult
    public func revokeViewer() -> Task<Void, Never>? { send(["event": "revoke"]) }

    /// Signed out, or the hub went away: end the session here (the caller told the hub first, when it could).
    func closeAll() { send(["event": "close_all"]) }

    // MARK: The reducer

    /// One event through the reducer: its session mirrors here, then its effects run. The task that
    /// waits on what the caller started (a Stop's `/end`, a Revoke's write), if any.
    @discardableResult
    private func send(_ event: [String: Any], ticket: SessionTicket? = nil) -> Task<Void, Never>? {
        var event = event
        let hub = hub()
        event["host"] = rdID
        event["hub"] = hub != nil
        let reply = MacScreenRules.rdHub("rd_hub_host_event", event)
        let next = (reply?["state"] as? [String: Any])?["session"] as? [String: Any]
        let mirrored = next.flatMap { s in
            (s["scope"] as? String).flatMap(SessionScope.init(rawValue:)).map {
                Session(id: s["id"] as? String ?? "", viewerID: s["viewer_id"] as? String ?? "", viewerName: s["viewer_name"] as? String ?? "",
                        scope: $0, ownAccount: s["own_account"] as? Bool ?? false, connected: s["connected"] as? Bool ?? false)
            }
        }
        if mirrored != session { session = mirrored }
        var waits: [Task<Void, Never>] = []
        for effect in RdEffect.all(reply) {
            let id = effect.sessionID, text = effect.reason, end = endSession
            switch (effect.name, hub) {
            case ("read_consent", _):
                guard let ticket, let consentGate, let arrival = effect.fields["arrival"] as? Int else { continue }
                // task-owner: one consent read per ticket; the ticket serves after it or is ended
                Task { [weak self] in
                    let allowed = await consentGate(ticket)
                    if !allowed { self?.logger.info("session ticket refused: this Mac's consent does not allow it") }
                    self?.send(["event": "consent_answered", "ticket": ticket.rdHost, "arrival": arrival, "allowed": allowed], ticket: ticket)
                }
            case let ("start", hub?):
                if let ticket { start(ticket, hub: hub) }
            case ("close_local", _): closeLocal()
            case let ("end", hub?):
                // task-owner: one /end call; the hub pushes the end to both Macs
                Task { await end(hub, id, text) }
            case let ("end_then_stop", hub?):
                // task-owner: one /end, then this session's stream closes (its revocation push may close it first)
                waits.append(Task { [weak self] in
                    await end(hub, id, text)
                    self?.send(["event": "stop_ended", "session_id": id])
                })
            case let ("revoke_permission", hub?):
                let revoke = revokePermission, viewer = effect.fields["viewer_id"] as? String ?? ""
                // task-owner: one permission write; the hub's revocation push closes the session
                waits.append(Task { [weak self] in
                    do { try await revoke(hub, viewer) } catch { await self?.send(["event": "revoke_failed"])?.value }
                })
            default: continue
            }
        }
        updateIndicator()
        return waits.isEmpty ? nil : Task { for wait in waits { await wait.value } }
    }

    private func start(_ ticket: SessionTicket, hub: DeviceHub) {
        let signaling: any ScreenSignaling
        do { signaling = try makeSignaling(ticket, hub) } catch {
            logger.error("session ticket refused: \(String(describing: error), privacy: .public)")
            send(["event": "start_failed", "session_id": ticket.sessionId])
            return
        }
        let host = makeHost(MacScreenRdHost.Session(id: ticket.sessionId, name: MacScreenShareHost.computerName, viewerID: ticket.peer.id, viewOnly: ticket.scope == .view,
                                                    servers: MacScreenRdServers(hub.iceServers(for: ticket).map(\.config))))
        let (events, sink) = AsyncStream.makeStream(of: MacScreenRdHost.Event.self, bufferingPolicy: .bufferingNewest(64))
        host.onEvent = { event in sink.yield(event) }
        self.host = host
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

    private func handle(_ event: MacScreenRdHost.Event, session id: String) {
        switch event {
        case .viewerConnected:
            send(["event": "viewer_connected", "session_id": id])
        case let .viewerEnded(reason):
            logger.info("session ended: \(reason, privacy: .public)")
            send(["event": "viewer_ended", "session_id": id])
        case let .sourceFailed(message):
            logger.error("screen host failed: \(message, privacy: .public)")
            send(["event": "source_failed", "session_id": id, "message": message])
        }
    }

    /// The host's serve loop returned (bye, closed, revoked).
    /// A connected session outlives its signaling (a dropped hub link): the
    /// viewer leaving, the hub's revocation or end, or Stop Sharing ends it.
    private func served(_ host: MacScreenRdHost, session id: String) {
        guard self.host === host else { return }
        send(["event": "served", "session_id": id])
    }

    /// Stops the screen host here (its process disconnects the viewer); the reducer already dropped the session.
    private func closeLocal() {
        let host = self.host
        self.host = nil
        host?.onEvent = nil
        // The host process stops its session and exits (writes on its own queue).
        host?.disconnectViewer()
        serveTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func updateIndicator() {
        guard let session, session.connected else {
            // No viewer: an owner's agent's share still shows, with Stop Sharing This Mac.
            if let agentShareTitle {
                indicator.setVisible(true)
                indicator.update(title: agentShareTitle, offersRevoke: false, offersTurnOff: true)
            } else {
                indicator.setVisible(false)
            }
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
    var indicatorTitle: String? { session?.connected == true || agentShareTitle != nil ? indicator.title : nil }

    // MARK: An owner's agent's share

    /// An owner's agent turned sharing on (the account's standing permission): the menu bar
    /// item says so until sharing goes off, by Turn Off, the person, the agent or the auto-off.
    /// Then `whenOff` runs once (the notice that it is off).
    public func showAgentShare(_ title: String, whenOff: @escaping @MainActor () -> Void) {
        agentShareTitle = title
        updateIndicator()
        agentShareWatch?.cancel()
        // task-owner: one watch per agent share; it ends when sharing goes off or a newer share replaces it
        agentShareWatch = Task { [weak self] in
            var wasOn = false
            for await on in ObservationStream({ [weak self] in self?.hub()?.thisDevice?.macScreenShared ?? false }) {
                if on { wasOn = true; continue }
                guard wasOn, let self, !Task.isCancelled else { continue }
                agentShareTitle = nil
                updateIndicator()
                whenOff()
                return
            }
        }
    }
}
