public import CmuxNextDevices
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
public import Observation

/// One Mac Screen tab's side of a device hub session, as the viewer: it asks
/// the hub for a session with one of the user's devices, waits for the
/// host's approval and the ticket, hands the ticket's signaling to the
/// tab's `ScreenSession` once, and ends at once on a denial, revocation or
/// end. Tickets admit once, so every new stream is a new request.
@MainActor @Observable
public final class MacScreenHubViewer {
    /// The host device (the hub's id).
    public let deviceID: String
    public internal(set) var phase: MacScreenHubPhase = .idle
    /// The scope the person asked for last (Try Again asks for it again).
    public internal(set) var lastScope: SessionScope = .full

    /// The hub, while this app is signed in to one.
    @ObservationIgnored var hub: @MainActor () -> DeviceHub?
    /// Starts the tab's stream (the signaling is ready): the pane connects its session.
    @ObservationIgnored var startStream: () -> Void = {}
    /// Stops the tab's stream now (revoked, ended, a new request).
    @ObservationIgnored var stopStream: () -> Void = {}
    /// Makes the session's signaling from a ticket; tests replace it.
    @ObservationIgnored var makeSignaling: @MainActor (SessionTicket, DeviceHub) throws -> any ScreenSignaling = MacScreenHubViewer.ticketSignaling
    /// Ends a session on the hub (`/end`); tests replace it.
    @ObservationIgnored var endSession: @MainActor (DeviceHub, String, String) async -> Void = { hub, id, reason in
        try? await hub.endSession(id, reason: reason)
    }
    /// DEV builds (Relay Only): the stream uses only TURN relays.
    @ObservationIgnored var relayOnly = false
    /// The signaling the next `ScreenSession.connect()` takes (once).
    @ObservationIgnored private var pendingSignaling: (any ScreenSignaling)?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    /// The tab hid past its grace mid-session: showing it asks again for this scope.
    @ObservationIgnored var resumeScope: SessionScope?

    public init(deviceID: String, hub: @escaping @MainActor () -> DeviceHub?) {
        self.deviceID = deviceID
        self.hub = hub
    }

    /// The session's signaling for `ticket`: the Session DO socket signed by
    /// this device, the ticket's cmux relay and the user's relays.
    static func ticketSignaling(_ ticket: SessionTicket, hub: DeviceHub) throws -> any ScreenSignaling {
        try TicketSignaling(ticket: ticket.ticket, signalURL: ticket.signalURL, signer: hub.identity,
                            iceServers: hub.iceServers(for: ticket).map(\.config), expectedPeerKey: ticket.peer.signingKey)
    }

    /// The signaling for `ScreenSession.connect()`: once per ticket.
    func takeSignaling() -> (any ScreenSignaling)? {
        defer { pendingSignaling = nil }
        return pendingSignaling
    }

    // MARK: Person

    /// Asks the host for a session (Connect, Try Again, a scope on the home page).
    public func request(_ scope: SessionScope) {
        failureEnd.cancel()
        failedWhileOffline = false
        cancelPending(endingSession: true)
        stopStream()
        lastScope = scope
        resumeScope = nil
        guard let hub = hub() else {
            phase = .refused(.notSignedIn, requested: scope)
            return
        }
        phase = .requesting(scope)
        let deviceID = deviceID
        requestTask = Task { [weak self] in
            let answer: Result<HubSession, DeviceHubError>
            do { answer = .success(try await hub.requestSession(host: deviceID, scope: scope)) } catch {
                answer = .failure(error as? DeviceHubError ?? .transport("\(error)"))
            }
            self?.requestReturned(answer, scope: scope, hub: hub, cancelled: Task.isCancelled)
        }
    }

    /// The request's HTTP answer came back. Cancelled (the person cancelled,
    /// or asked again) ends the session it made, unless this tab already runs
    /// that session (its ticket came first): ends are keyed to session ids.
    /// The `/end` it sends, if any (tests wait on it).
    @discardableResult
    func requestReturned(_ answer: Result<HubSession, DeviceHubError>, scope: SessionScope, hub: DeviceHub,
                         cancelled: Bool) -> Task<Void, Never>? {
        guard cancelled else {
            requestAnswered(answer, scope: scope, hub: hub)
            return nil
        }
        guard case let .success(session) = answer, phase.sessionID != session.id else { return nil }
        return end(session.id, reason: MacScreenHubReason.viewerDisconnected.rawValue, on: hub)
    }

    /// The hub's answer to `request(_:)` (tests call it directly).
    func requestAnswered(_ answer: Result<HubSession, DeviceHubError>, scope: SessionScope, hub: DeviceHub?) {
        // A ticket may have come before the answer (pushes race the HTTP reply): it already moved on.
        guard case .requesting = phase else { return }
        switch answer {
        case let .success(session):
            if let hub, let ticket = hub.tickets[session.id] {
                accept(ticket)
                return
            }
            switch session.state {
            case .pending?:
                phase = .waitingForApproval(sessionID: session.id, scope: scope)
                scheduleExpiry(session.id, hub: hub)
            case .ended?: phase = .ended(reason: nil)
            case .approved?, .live?, nil: phase = .approved(sessionID: session.id, scope: session.scope ?? scope)
            }
        case let .failure(error):
            phase = .refused(MacScreenHubRefusal(error), requested: scope)
        }
    }

    /// Cancel on a waiting card: the request ends (the host's prompt goes away).
    public func cancel() {
        cancelPending(endingSession: true)
        phase = .idle
    }

    /// Disconnect, or the tab closed: the session ends on both Macs. The hub
    /// hears the reason first (`/end`), then the stream stops, so the other
    /// Mac reads why rather than a dropped connection. `then` runs once the
    /// stream may stop (a closing tab closes its session there).
    public func disconnect(reason: MacScreenHubReason, closingTab: Bool = false, then: (() -> Void)? = nil) {
        let id = phase.sessionID
        let streaming = phase.streamingScope != nil
        cancelPending(endingSession: true)
        phase = closingTab ? .idle : .ended(reason: reason.rawValue)
        guard streaming, let id, let hub = hub() else {
            stopStream()
            then?()
            return
        }
        // task-owner: one /end before the stream stops; a newer session of this tab keeps running
        let end = endSession
        Task { [weak self] in
            await end(hub, id, reason.rawValue)
            if let self, phase.sessionID == nil { stopStream() }
            then?()
        }
    }

    /// The tab hid past its grace: the session ends, and showing the tab asks again.
    func endForHiddenTab() {
        guard let scope = phase.streamingScope else { return }
        disconnect(reason: .viewerDisconnected)
        resumeScope = scope
        phase = .idle
    }

    /// The session this tab's stream failed in: its card says why (a relay's
    /// error), and the hub's revocation for it does not replace that card.
    @ObservationIgnored private(set) var failedSession: String?

    /// How long a dropped stream waits for the hub's reason before telling it "failed":
    /// the host's cause (signed_out, sharing_off) often follows its stream's end.
    @ObservationIgnored var failureGrace: Duration = .seconds(3)
    /// The pending "failed" end; tests give it a manual clock.
    @ObservationIgnored var failureEnd = DemandTimer(owner: "mac-screen.hub-failure-grace")
    /// The stream failed while this Mac's own hub link was down: the card keeps saying so after it returns.
    @ObservationIgnored private(set) var failedWhileOffline = false

    /// The stream failed to start or dropped. The hub hears `failed` only if
    /// no reason of its own arrives within the grace, so a host's cause that
    /// is on its way (it often comes a moment after the stream drops) wins.
    func streamFailed() {
        guard let id = phase.sessionID, let scope = phase.streamingScope else { return }
        failedSession = id
        // The hub state follows the tab: no longer streaming (debug.device_hub, pushes keyed to the id).
        phase = .streamFailed(sessionID: id, scope: scope)
        failedWhileOffline = !hubConnected
        guard let hub = hub() else { return }
        // One delayed /end for this failed session (the wait for the hub's own reason); a push for it cancels it.
        failureEnd.schedule(after: failureGrace) { @MainActor [weak self] in
            guard let self, phase.sessionID == id else { return }
            await endSession(hub, id, MacScreenHubReason.failed.rawValue)
        }
    }

    /// The scope Connect Again asks for: what the host allows now (Full
    /// re-granted asks for Full, View for View), else the last one asked.
    static func scopeToRequest(last: SessionScope, access: DeviceScope?) -> SessionScope {
        switch access {
        case .full?: .full
        case .view?: .view
        default: last
        }
    }

    /// How long a request may wait for the host (PROTOCOL.md: requests expire after 5 min).
    @ObservationIgnored var approvalTimeout: Duration = .seconds(300)
    /// The running expiry of the request on screen; tests give it a manual clock.
    @ObservationIgnored var approvalExpiry = DemandTimer(owner: "mac-screen.hub-request-expiry")

    /// The host never answered: past the hub's expiry the request ends here
    /// too, with the expired card, instead of waiting for a host that may never act.
    private func scheduleExpiry(_ id: String, hub: DeviceHub?) {
        // One expiry per waiting request (the protocol's request lifetime); a decision, a cancel or a new request cancels it.
        approvalExpiry.schedule(after: approvalTimeout) { @MainActor [weak self] in
            guard let self, case let .waitingForApproval(waiting, _) = phase, waiting == id else { return }
            if let hub { await endSession(hub, id, "expired") }
            if case .waitingForApproval(id, _) = phase { phase = .ended(reason: "expired") }
        }
    }

    private func cancelPending(endingSession: Bool) {
        requestTask?.cancel()
        requestTask = nil
        approvalExpiry.cancel()
        pendingSignaling = nil
        if endingSession, phase.isPending, let id = phase.sessionID, let hub = hub() {
            end(id, reason: MacScreenHubReason.viewerDisconnected.rawValue, on: hub)
        }
    }

    @discardableResult
    private func end(_ id: String, reason: String, on hub: DeviceHub) -> Task<Void, Never> {
        let end = endSession
        // task-owner: one /end call; the hub's push (or its absence) settles the state
        return Task { await end(hub, id, reason) }
    }

    // MARK: Pushes

    /// Whether a `session.ticket` for the viewer names this tab's request:
    /// its session, or (before the request's answer) its host.
    func accepts(_ ticket: SessionTicket) -> Bool {
        guard ticket.role == .viewer else { return false }
        if let id = phase.sessionID { return id == ticket.sessionId }
        if case .requesting = phase { return ticket.peer.id == deviceID }
        return false
    }

    /// The session is approved: its signaling goes to the stream.
    func accept(_ ticket: SessionTicket) {
        // The request's answer may still be out: it finds this session running and changes nothing.
        approvalExpiry.cancel()
        guard let hub = hub() else { return }
        do {
            pendingSignaling = try makeSignaling(ticket, hub)
        } catch {
            end(ticket.sessionId, reason: MacScreenHubReason.failed.rawValue, on: hub)
            phase = .refused(.other, requested: ticket.scope)
            return
        }
        lastScope = ticket.scope
        phase = .streaming(sessionID: ticket.sessionId, scope: ticket.scope)
        startStream()
    }

    /// `session.denied`: the host's person said Deny.
    func denied() {
        let scope: SessionScope
        switch phase {
        case let .waitingForApproval(_, requested), let .approved(_, requested): scope = requested
        case let .requesting(requested): scope = requested
        default: scope = lastScope
        }
        requestTask?.cancel()
        approvalExpiry.cancel()
        pendingSignaling = nil
        phase = .declined(scope)
    }

    /// `session.revoked`: end now, and say why.
    func revoked(reason: String?) {
        failureEnd.cancel()
        if keepsFailedCard(reason) { return }
        requestTask?.cancel()
        approvalExpiry.cancel()
        pendingSignaling = nil
        stopStream()
        phase = .revoked(reason: reason)
    }

    /// `session.ended`.
    func ended(reason: String?) {
        failureEnd.cancel()
        if keepsFailedCard(reason) { return }
        requestTask?.cancel()
        approvalExpiry.cancel()
        pendingSignaling = nil
        stopStream()
        if case .revoked = phase { return }
        phase = .ended(reason: reason)
    }

    /// The stream failed first and the hub's end only echoes this tab's own
    /// `failed`: the failed card (which says why) stays. Any other reason is
    /// the cause (the host stopped, turned sharing off, revoked) and wins.
    private func keepsFailedCard(_ reason: String?) -> Bool {
        guard let failed = failedSession, failed == phase.sessionID else { return false }
        let cause = MacScreenEndReason(reason)
        return cause == .failed || cause == .other
    }

    /// Signed out of the hub, or this Mac was removed (`reason`): a request or
    /// stream in progress is over. A tab that already shows an end keeps it.
    func hubGone(reason: String = MacScreenHubReason.signedOut.rawValue) {
        guard phase.isPending || phase.streamingScope != nil else { return }
        requestTask?.cancel()
        approvalExpiry.cancel()
        pendingSignaling = nil
        stopStream()
        phase = .ended(reason: reason)
    }

    /// The hub's view of the host: offline while this tab streams means the
    /// stream is dead or about to be (the hub knows within its offline grace),
    /// so it ends now with that reason instead of waiting on WebRTC.
    func hostOnlineChanged(_ online: Bool) {
        hostOnline = online
        endIfHostGone()
    }

    /// The stream stalled (ICE disconnected) or recovered.
    func streamStalled(_ stalled: Bool) {
        self.stalled = stalled
        endIfHostGone()
    }

    @ObservationIgnored private var hostOnline = true
    @ObservationIgnored private var stalled = false

    /// A stalled stream whose host the hub lists offline is over: end it now
    /// rather than wait for WebRTC. Either alone is not enough: a host's
    /// short hub drop leaves a live stream alone, and a stall may recover.
    private func endIfHostGone() {
        guard !hostOnline, stalled, phase.streamingScope != nil else { return }
        failureEnd.cancel()
        stalled = false
        stopStream()
        phase = .ended(reason: "peer_offline")
    }

    /// This Mac's own link to the hub is up (a failed stream then blames neither Mac's network).
    var hubConnected: Bool { hub()?.connection == .connected }

    /// This Mac's current access to the host (the host's permission list, as last read).
    var accessToHost: DeviceScope? {
        guard let hub = hub() else { return nil }
        return hub.scope(host: deviceID, viewer: hub.identity.id)
    }
}
