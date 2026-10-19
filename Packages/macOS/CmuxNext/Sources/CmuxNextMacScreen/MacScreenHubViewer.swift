public import CmuxNextDevices
public import CmuxScreenKit
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
            guard let self else { return }
            if Task.isCancelled {
                // The person cancelled while the request was out: end the session it made.
                if case let .success(session) = answer { Self.end(session.id, reason: .viewerDisconnected, on: hub) }
                return
            }
            requestAnswered(answer, scope: scope, hub: hub)
        }
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
            case .pending?: phase = .waitingForApproval(sessionID: session.id, scope: scope)
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

    /// Disconnect, or the tab closed: the session ends on both Macs.
    public func disconnect(reason: MacScreenHubReason) {
        let id = phase.sessionID
        cancelPending(endingSession: true)
        stopStream()
        if let id, let hub = hub() { Self.end(id, reason: reason, on: hub) }
        phase = reason == .tabClosed ? .idle : .ended(reason: reason.rawValue)
    }

    /// The tab hid past its grace: the session ends, and showing the tab asks again.
    func endForHiddenTab() {
        guard let scope = phase.streamingScope else { return }
        disconnect(reason: .viewerDisconnected)
        resumeScope = scope
        phase = .idle
    }

    /// The stream failed to start or dropped: the session is over for the hub too.
    func streamFailed() {
        guard let id = phase.sessionID, let hub = hub() else { return }
        Self.end(id, reason: .failed, on: hub)
    }

    private func cancelPending(endingSession: Bool) {
        requestTask?.cancel()
        requestTask = nil
        pendingSignaling = nil
        if endingSession, phase.isPending, let id = phase.sessionID, let hub = hub() {
            Self.end(id, reason: .viewerDisconnected, on: hub)
        }
    }

    private static func end(_ id: String, reason: MacScreenHubReason, on hub: DeviceHub) {
        // task-owner: one /end call; the hub's push (or its absence) settles the state
        Task { try? await hub.endSession(id, reason: reason.rawValue) }
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
        requestTask?.cancel()
        requestTask = nil
        guard let hub = hub() else { return }
        do {
            pendingSignaling = try makeSignaling(ticket, hub)
        } catch {
            Self.end(ticket.sessionId, reason: .failed, on: hub)
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
        pendingSignaling = nil
        phase = .declined(scope)
    }

    /// `session.revoked`: end now, and say why.
    func revoked(reason: String?) {
        requestTask?.cancel()
        pendingSignaling = nil
        stopStream()
        phase = .revoked(reason: reason)
    }

    /// `session.ended`.
    func ended(reason: String?) {
        requestTask?.cancel()
        pendingSignaling = nil
        stopStream()
        if case .revoked = phase { return }
        phase = .ended(reason: reason)
    }

    /// Signed out of the hub (or it went away): any session is over.
    func hubGone() {
        guard phase != .idle else { return }
        requestTask?.cancel()
        pendingSignaling = nil
        stopStream()
        if case .refused = phase { return }
        phase = .ended(reason: MacScreenHubReason.signedOut.rawValue)
    }
}
