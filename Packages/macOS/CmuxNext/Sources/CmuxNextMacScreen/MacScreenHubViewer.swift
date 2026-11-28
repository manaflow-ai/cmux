public import CmuxNextDevices
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
public import Observation
import os

/// One Mac Screen tab's side of a device hub session, as the viewer: it asks
/// the hub for a session with one of the user's devices, waits for the
/// host's approval and the ticket, hands the ticket's signaling to the
/// tab's `MacScreenSession` once, and ends at once on a denial, revocation or
/// end. Tickets admit once, so every new stream is a new request.
@MainActor @Observable
public final class MacScreenHubViewer {
    /// Notice level, so `log show` finds it after the fact: each request, each `/end` this tab sends and each
    /// stream failure, with the tab, the host and the session (the double-request question needs all three).
    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen")
    /// This tab's viewer in the log: stable for the tab's life, short.
    private var logTab: String { String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xffffff, radix: 16) }

    private func logEnd(_ id: String, _ reason: String, _ site: String) {
        Self.log.notice("end: tab \(self.logTab, privacy: .public) device \(self.deviceID, privacy: .public) session \(id, privacy: .public) reason \(reason, privacy: .public) from \(site, privacy: .public)")
    }

    /// The host device (the hub's id).
    public let deviceID: String
    /// cmux-rd-core's viewer reducer for this tab (`rd_hub_viewer_*`) decides; this class mirrors its
    /// state and runs its effects (hub calls, timers, the stream). Setting `phase` (tests, galleries)
    /// sets the reducer's.
    public internal(set) var phase: MacScreenHubPhase = .idle {
        didSet { if !mirroring { mirror(MacScreenRules.rdHub("rd_hub_viewer_set_phase", ["id": rdID, "phase": phase.rd])) } }
    }
    /// The scope the person asked for last (Try Again asks for it again).
    public internal(set) var lastScope: SessionScope = .full
    /// The host's own reason this session failed, from the hub's end (`failed: <reason>`, which
    /// the host sends when it could not start serving: no helper, a helper that stopped before
    /// the link); nil when no host reason came. A new request clears it.
    public internal(set) var hostFailure: String?
    /// The session that ended here because the share moved (`session.ended` reason `moved`): its
    /// replacement, when the hub pushes it to this app, finds this tab by it. Nil otherwise.
    public internal(set) var movedSession: String?
    /// The tab hid past its grace mid-session: showing it asks again for this scope.
    public internal(set) var resumeScope: SessionScope?
    /// The session this tab's stream failed in: its card says why (a relay's
    /// error), and the hub's revocation for it does not replace that card.
    @ObservationIgnored private(set) var failedSession: String?
    /// The stream failed while this Mac's own hub link was down: the card keeps saying so after it returns.
    @ObservationIgnored private(set) var failedWhileOffline = false

    /// The hub, while this app is signed in to one.
    @ObservationIgnored var hub: @MainActor () -> DeviceHub?
    /// Starts the tab's stream (the signaling is ready): the pane connects its session.
    @ObservationIgnored var startStream: () -> Void = {}
    /// A session started streaming, by any path to `accept(_:)` (the pages mark that this Mac has viewed another).
    @ObservationIgnored var onStreaming: () -> Void = {}
    /// Stops the tab's stream now (revoked, ended, a new request).
    @ObservationIgnored var stopStream: () -> Void = {}
    /// Makes the session's signaling from a ticket; tests replace it.
    @ObservationIgnored var makeSignaling: @MainActor (SessionTicket, DeviceHub) throws -> any ScreenSignaling = MacScreenHubViewer.ticketSignaling
    /// Ends a session on the hub (`/end`); tests replace it.
    @ObservationIgnored var endSession: @MainActor (DeviceHub, String, String) async -> Void = { hub, id, reason in
        try? await hub.endSession(id, reason: reason)
    }
    /// Asks the hub again for an approved session's viewer ticket (`/reattach`); tests replace it.
    @ObservationIgnored var reattachSession: @MainActor (DeviceHub, String) async throws -> SessionTicket = { hub, id in
        try await hub.reattachSession(id)
    }
    /// DEV builds (Relay Only): the stream uses only TURN relays.
    @ObservationIgnored var relayOnly = false
    /// The signaling the next `MacScreenSession.connect()` takes (once).
    @ObservationIgnored private var pendingSignaling: (any ScreenSignaling)?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    /// How long a dropped stream waits for the hub's reason before telling it "failed":
    /// the host's cause (signed_out, sharing_off) often follows its stream's end.
    @ObservationIgnored var failureGrace: Duration = .seconds(3)
    /// The pending "failed" end; tests give it a manual clock.
    @ObservationIgnored var failureEnd = DemandTimer(owner: "mac-screen.hub-failure-grace")
    /// How long a request may wait for the host (PROTOCOL.md: requests expire after 5 min).
    @ObservationIgnored var approvalTimeout: Duration = .seconds(300)
    /// The running expiry of the request on screen; tests give it a manual clock.
    @ObservationIgnored var approvalExpiry = DemandTimer(owner: "mac-screen.hub-request-expiry")
    /// How long an approved session waits for its `session.ticket` push before asking the hub for it.
    @ObservationIgnored var ticketWait: Duration = .seconds(8)
    /// The running wait for the ticket on screen; tests give it a manual clock.
    @ObservationIgnored var ticketDeadline = DemandTimer(owner: "mac-screen.hub-ticket-wait")
    @ObservationIgnored private let rdID = UUID().uuidString
    @ObservationIgnored private var mirroring = false

    public init(deviceID: String, hub: @escaping @MainActor () -> DeviceHub?) {
        self.deviceID = deviceID
        self.hub = hub
        _ = MacScreenRules.rdHub("rd_hub_viewer_open", ["id": rdID, "device_id": deviceID])
    }

    nonisolated deinit { _ = MacScreenRules.rdHub("rd_hub_viewer_close", ["id": rdID]) }

    /// The session's signaling for `ticket`: the Session DO socket signed by
    /// this device, the ticket's cmux relay and the user's relays.
    static func ticketSignaling(_ ticket: SessionTicket, hub: DeviceHub) throws -> any ScreenSignaling {
        try TicketSignaling(ticket: ticket.ticket, signalURL: ticket.signalURL, signer: hub.identity,
                            iceServers: hub.iceServers(for: ticket).map(\.config), expectedPeerKey: ticket.peer.signingKey)
    }

    /// The signaling for `MacScreenSession.connect()`: once per ticket.
    func takeSignaling() -> (any ScreenSignaling)? {
        defer { pendingSignaling = nil }
        return pendingSignaling
    }

    // MARK: Person

    /// Asks the host for a session (Connect, Try Again, a scope on the home page).
    public func request(_ scope: SessionScope) {
        let pending = phase.isPending || requestTask != nil
        Self.log.notice("request: tab \(self.logTab, privacy: .public) device \(self.deviceID, privacy: .public) scope \(scope.rawValue, privacy: .public) session \(self.phase.sessionID ?? "-", privacy: .public) pending \(pending, privacy: .public)")
        send(["event": "request", "scope": scope.rawValue], site: "pending request replaced")
    }

    /// A hub came (the saved sign-in finished restoring, or the person signed in): a tab
    /// refused only because there was none asks again for the scope it wanted.
    func hubArrived() { send(["event": "hub_arrived"], site: "pending request replaced") }

    /// The request's HTTP answer came back. Cancelled (the person cancelled, or asked again) ends the
    /// session it made, unless this tab already runs that session. The `/end` it sends, if any (tests wait on it).
    @discardableResult
    func requestReturned(_ answer: Result<HubSession, DeviceHubError>, scope: SessionScope, hub: DeviceHub?,
                         cancelled: Bool) -> Task<Void, Never>? {
        var event: [String: Any] = ["event": "request_returned", "answer": rdAnswer(answer) { $0.rd }, "scope": scope.rawValue,
                                    "cancelled": cancelled, "hub": hub != nil]
        var signaling: (any ScreenSignaling)?
        // A ticket may have come before the answer (pushes race the HTTP reply).
        if !cancelled, case .requesting = phase, case let .success(session) = answer, let hub, let ticket = hub.tickets[session.id] {
            event["ticket"] = ticket.rdViewer
            signaling = prepare(ticket, hub: hub, into: &event)
        }
        return Self.joined(send(event, hub: hub, signaling: signaling, site: "cancelled request's answer"))
    }

    /// The hub's answer to `request(_:)` (tests call it directly).
    func requestAnswered(_ answer: Result<HubSession, DeviceHubError>, scope: SessionScope, hub: DeviceHub?) {
        requestReturned(answer, scope: scope, hub: hub, cancelled: false)
    }

    /// Cancel on a waiting card: the request ends (the host's prompt goes away).
    public func cancel() { send(["event": "cancel"], site: "pending request cancelled") }

    /// Disconnect, or the tab closed: the session ends on both Macs. The hub
    /// hears the reason first (`/end`), then the stream stops, so the other
    /// Mac reads why rather than a dropped connection. `then` runs once the
    /// stream may stop (a closing tab closes its session there).
    public func disconnect(reason: MacScreenHubReason, closingTab: Bool = false, site: String = "stop viewing", then: (() -> Void)? = nil) {
        send(["event": "disconnect", "reason": reason.rawValue, "closing_tab": closingTab], site: closingTab ? "tab closed" : site, then: then)
    }

    /// The tab hid past its grace: the session ends, and showing the tab asks again.
    func endForHiddenTab() { send(["event": "end_for_hidden_tab"], site: "tab hidden past its grace") }

    /// The stream failed to start or dropped. The hub hears `failed` only if
    /// no reason of its own arrives within the grace, so a host's cause that
    /// is on its way (it often comes a moment after the stream drops) wins.
    func streamFailed(stage: String? = nil, message: String? = nil) {
        if let id = phase.sessionID, phase.streamingScope != nil {
            Self.log.notice("stream failed: tab \(self.logTab, privacy: .public) device \(self.deviceID, privacy: .public) session \(id, privacy: .public) stage \(stage ?? "-", privacy: .public) hub connected \(self.hubConnected, privacy: .public) message \(message ?? "-", privacy: .public)")
        }
        send(["event": "stream_failed", "hub_connected": hubConnected], site: "stream failed, no hub reason in the grace")
    }

    /// The scope Connect Again asks for: what the host allows now (Full
    /// re-granted asks for Full, View for View), else the last one asked.
    /// cmux-rd-core's `rd_hub_scope_to_request` decides.
    static func scopeToRequest(last: SessionScope, access: DeviceScope?) -> SessionScope {
        var request: [String: Any] = ["last": last.rawValue]
        if let access { request["access"] = access.rawValue }
        return (MacScreenRules.rdHub("rd_hub_scope_to_request", request)?["scope"] as? String).flatMap(SessionScope.init(rawValue:)) ?? last
    }

    // MARK: Pushes

    /// Whether a `session.ticket` for the viewer names this tab's request:
    /// its session, or (before the request's answer) its host.
    func accepts(_ ticket: SessionTicket) -> Bool {
        MacScreenRules.rdHub("rd_hub_viewer_accepts", ["id": rdID, "ticket": ticket.rdViewer])?["accepts"] as? Bool ?? false
    }

    /// The session is approved: its signaling goes to the stream.
    func accept(_ ticket: SessionTicket) {
        var event: [String: Any] = ["event": "accept", "ticket": ticket.rdViewer]
        let signaling = hub().flatMap { prepare(ticket, hub: $0, into: &event) }
        send(event, signaling: signaling, site: "ticket signaling")
    }

    /// A viewer ticket for this tab's host that no request here asked for: the hub pushed it (a
    /// share moved to this Mac, a host pushed its screen here). What the tab ran or showed stops,
    /// and the ticket streams, as if a person had pressed Connect and the host had answered.
    func acceptPushed(_ ticket: SessionTicket) {
        var event: [String: Any] = ["event": "accept_pushed", "ticket": ticket.rdViewer]
        let signaling = ticket.role == .viewer && ticket.peer.id == deviceID ? hub().flatMap { prepare(ticket, hub: $0, into: &event) } : nil
        send(event, signaling: signaling, site: "pushed ticket")
    }

    /// `session.denied`: the host's person said Deny.
    func denied() { send(["event": "denied"]) }

    /// `session.revoked`: end now, and say why.
    func revoked(reason: String?) { send(["event": "revoked", "reason": reason as Any? ?? NSNull()]) }

    /// `session.ended`. Reason `moved`: a new session replaced this one; the tab remembers which
    /// ended so the replacement, if it comes to this app, takes the tab over (no failed card).
    func ended(reason: String?) { send(["event": "ended", "reason": reason as Any? ?? NSNull()]) }

    /// Signed out of the hub, or this Mac was removed (`reason`): a request or
    /// stream in progress is over. A tab that already shows an end keeps it.
    func hubGone(reason: String = MacScreenHubReason.signedOut.rawValue) { send(["event": "hub_gone", "reason": reason]) }

    /// The hub's view of the host: offline while this tab streams (and stalls) ends it now.
    func hostOnlineChanged(_ online: Bool) { send(["event": "host_online", "online": online]) }

    /// The stream stalled (ICE disconnected) or recovered.
    func streamStalled(_ stalled: Bool) { send(["event": "stream_stalled", "stalled": stalled]) }

    // MARK: The reducer

    /// The ticket's signaling, made before the reducer decides (it reads only whether making it
    /// failed): nil, with `signaling_error`, when it failed; nil when the tab already streams it.
    private func prepare(_ ticket: SessionTicket, hub: DeviceHub, into event: inout [String: Any]) -> (any ScreenSignaling)? {
        if case let .streaming(id, _) = phase, id == ticket.sessionId { return nil }
        do { return try makeSignaling(ticket, hub) } catch {
            event["signaling_error"] = (error as? DeviceHubError ?? .transport(error.localizedDescription)).rd
            return nil
        }
    }

    /// One event through the reducer: its state mirrors here, then its effects run. The `/end`s it
    /// sends (and a reattach) come back, so a timer's work finishes with them.
    @discardableResult
    private func send(_ event: [String: Any], hub override: DeviceHub? = nil, signaling: (any ScreenSignaling)? = nil,
                      site: String = "", then: (() -> Void)? = nil) -> [Task<Void, Never>] {
        let hub = override ?? hub()
        var event = event
        event["hub"] = event["hub"] ?? (hub != nil)
        let reply = MacScreenRules.rdHub("rd_hub_viewer_event", ["id": rdID, "event": event])
        mirror(reply?["state"] as? [String: Any])
        var tasks: [Task<Void, Never>] = []
        // One timer per kind; firing sends its `_due` event and waits on what that starts.
        func due(_ timer: DemandTimer, _ after: Duration, _ name: String, _ id: String, _ site: String) {
            timer.schedule(after: after) { @MainActor [weak self] in
                for task in self?.send(["event": name, "session_id": id], site: site) ?? [] { await task.value }
            }
        }
        for effect in RdEffect.all(reply) {
            let id = effect.sessionID, reason = effect.reason, end = endSession
            switch (effect.name, hub) {
            case let ("send_request", hub?):
                guard let scope = (effect.fields["scope"] as? String).flatMap(SessionScope.init(rawValue:)) else { continue }
                let deviceID = deviceID
                requestTask = Task { [weak self] in
                    let answer = await Self.answer { try await hub.requestSession(host: deviceID, scope: scope) }
                    self?.requestReturned(answer, scope: scope, hub: hub, cancelled: Task.isCancelled)
                }
            case ("cancel_request", _):
                requestTask?.cancel()
                requestTask = nil
            case let ("end_on_hub", hub?):
                logEnd(id, reason, site)
                // task-owner: one /end call; the hub's push (or its absence) settles the state
                tasks.append(Task { await end(hub, id, reason) })
            case let ("end_on_hub_then_stop", hub?):
                logEnd(id, reason, site)
                // task-owner: one /end before the stream stops; a newer session of this tab keeps running
                tasks.append(Task { [weak self] in
                    await end(hub, id, reason)
                    if let self { send(["event": "disconnect_ended"], then: then) } else { then?() }
                })
            case ("stop_stream", _): stopStream()
            case ("start_stream", _): startStream()
            case ("on_streaming", _): onStreaming()
            case ("use_signaling", _): pendingSignaling = signaling
            case ("drop_signaling", _): pendingSignaling = nil
            case ("then", _): then?()
            case ("schedule_failure_end", _): due(failureEnd, failureGrace, "failure_end_due", id, "stream failed, no hub reason in the grace")
            case ("schedule_expiry", _): due(approvalExpiry, approvalTimeout, "expiry_due", id, "approval expiry")
            case ("schedule_ticket_wait", _): due(ticketDeadline, ticketWait, "ticket_wait_due", id, "ticket wait")
            case ("cancel_failure_end", _): failureEnd.cancel()
            case ("cancel_timers", _):
                approvalExpiry.cancel()
                ticketDeadline.cancel()
            case let ("reattach", hub?):
                let reattach = reattachSession
                // task-owner: one /reattach for an approved session whose ticket never came
                tasks.append(Task { [weak self] in
                    let answer = await Self.answer { try await reattach(hub, id) }
                    guard let self else { return }
                    var event: [String: Any] = ["event": "reattach_answered", "session_id": id, "answer": rdAnswer(answer) { $0.rdViewer }]
                    let signaling = (try? answer.get()).flatMap { prepare($0, hub: hub, into: &event) }
                    for task in send(event, hub: hub, signaling: signaling, site: "ticket wait") { await task.value }
                })
            default: continue
            }
        }
        return tasks
    }

    private static func answer<T>(_ call: () async throws -> T) async -> Result<T, DeviceHubError> {
        do { return .success(try await call()) } catch { return .failure(error as? DeviceHubError ?? .transport("\(error)")) }
    }

    private func mirror(_ state: [String: Any]?) {
        guard let state else { return }
        mirroring = true
        defer { mirroring = false }
        if let next = MacScreenHubPhase(rd: state["phase"] as? [String: Any]), next != phase { phase = next }
        let scope = { (key: String) in (state[key] as? String).flatMap(SessionScope.init(rawValue:)) }
        if let last = scope("last_scope"), last != lastScope { lastScope = last }
        if scope("resume_scope") != resumeScope { resumeScope = scope("resume_scope") }
        if state["host_failure"] as? String != hostFailure { hostFailure = state["host_failure"] as? String }
        if state["moved_session"] as? String != movedSession { movedSession = state["moved_session"] as? String }
        failedSession = state["failed_session"] as? String
        failedWhileOffline = state["failed_while_offline"] as? Bool ?? false
    }

    private static func joined(_ tasks: [Task<Void, Never>]) -> Task<Void, Never>? {
        tasks.isEmpty ? nil : Task { for task in tasks { await task.value } }
    }

    /// This Mac's own link to the hub is up (a failed stream then blames neither Mac's network).
    var hubConnected: Bool { hub()?.connection == .connected }

    /// This Mac's current access to the host (the host's permission list, as last read).
    var accessToHost: DeviceScope? {
        guard let hub = hub() else { return nil }
        return hub.scope(host: deviceID, viewer: hub.identity.id)
    }
}
