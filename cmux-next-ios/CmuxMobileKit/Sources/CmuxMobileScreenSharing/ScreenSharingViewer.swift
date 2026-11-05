#if os(iOS)
public import CmuxDeviceHub
public import CmuxScreenKit
public import Foundation
public import Observation

/// Why a session ended on this phone, as `/end` reasons (PROTOCOL.md, End reasons).
public enum ScreenSharingEndReason: String, Sendable {
    case viewerDisconnected = "viewer_disconnected"
    case signedOut = "signed_out"
    case failed
}

/// One Screen Sharing session from this phone to a Mac, as the viewer: it
/// asks the hub for a session, waits for the Mac's approval and ticket, hands
/// the ticket's signaling to its `ScreenSession` once, and ends at once on a
/// denial, revocation or end. Tickets admit once, so every new stream is a
/// new request (`reconnectLimit` 0; Try Again asks again).
@MainActor @Observable
public final class ScreenSharingViewer: Identifiable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The request is on its way to the hub.
        case requesting(SessionScope)
        /// The Mac asks its person (its permission for this phone is Ask, or below the scope).
        case waitingForApproval(sessionID: String, scope: SessionScope)
        /// Approved; the ticket is on its way.
        case approved(sessionID: String, scope: SessionScope)
        case streaming(sessionID: String, scope: SessionScope)
        /// The Mac's person said Deny.
        case declined(SessionScope)
        /// The hub refused the request.
        case refused(ScreenSharingRefusal, requested: SessionScope)
        /// The session is over (`reason` from the hub, or this phone's own).
        case ended(reason: String?)
    }

    public nonisolated var id: String { hostID }
    public nonisolated let hostID: String
    public let hostName: String
    public private(set) var phase: Phase = .idle
    /// The stream while approved (nil before the ticket and after the end).
    public private(set) var screen: ScreenSession?
    public private(set) var lastScope: SessionScope = .full

    @ObservationIgnored let hub: DeviceHub
    @ObservationIgnored let preferences: ScreenSharingPreferences
    /// Makes the session's signaling from a ticket; tests replace it.
    @ObservationIgnored var makeSignaling: @MainActor (SessionTicket, DeviceHub) throws -> any ScreenSignaling = ScreenSharingViewer.ticketSignaling
    /// Ends a session on the hub (`/end`); tests replace it.
    @ObservationIgnored var endSession: @MainActor (DeviceHub, String, String) async -> Void = { hub, id, reason in
        try? await hub.endSession(id, reason: reason)
    }
    /// Asks the hub for a session (`POST /v1/sessions`); tests replace it.
    @ObservationIgnored var requestSession: @MainActor (DeviceHub, String, SessionScope) async throws -> HubSession = { hub, host, scope in
        try await hub.requestSession(host: host, scope: scope)
    }
    /// Starts the stream (tests replace it: no WebRTC there).
    @ObservationIgnored var startStream: @MainActor (ScreenSession) -> Void = { $0.connect() }
    /// Every session this viewer ended or left on the hub (the service ignores later tickets for them).
    @ObservationIgnored var sessionLeft: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored private var pendingSignaling: (any ScreenSignaling)?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    /// A denial or end the hub pushed before the request's HTTP answer named its session.
    @ObservationIgnored private var earlyOutcomes: [String: Phase] = [:]

    init(hostID: String, hostName: String, hub: DeviceHub, preferences: ScreenSharingPreferences) {
        self.hostID = hostID
        self.hostName = hostName
        self.hub = hub
        self.preferences = preferences
    }

    /// The session id the hub knows this viewer by, once it answered.
    public var sessionID: String? {
        switch phase {
        case let .waitingForApproval(id, _), let .approved(id, _), let .streaming(id, _): id
        default: nil
        }
    }

    /// Whether a request or stream is in progress (the waiting card or the screen shows).
    public var isActive: Bool {
        switch phase {
        case .requesting, .waitingForApproval, .approved, .streaming: true
        default: false
        }
    }

    /// The session's signaling: the Session DO socket signed by this phone, the
    /// ticket's cmux relay and the user's own relays.
    static func ticketSignaling(_ ticket: SessionTicket, hub: DeviceHub) throws -> any ScreenSignaling {
        try TicketSignaling(ticket: ticket.ticket, signalURL: ticket.signalURL, signer: hub.identity,
                            iceServers: hub.iceServers(for: ticket).map(\.config), expectedPeerKey: ticket.peer.signingKey)
    }

    // MARK: Person

    /// Asks the Mac for a session (Connect, Try Again).
    public func request(_ scope: SessionScope) {
        droppedSessionID = nil
        cancelPending(endingSession: true)
        stopStream()
        lastScope = scope
        phase = .requesting(scope)
        let hub = hub, hostID = hostID, requestSession = requestSession, endSession = endSession, sessionLeft = sessionLeft
        requestTask = Task { [weak self] in
            // The call runs in its own task, which cancelling this one does not cancel: the hub may
            // have made the session already, and only its answer says which one to end.
            // task-owner: one POST /v1/sessions; its answer is always read below
            let call = Task { @MainActor in try await requestSession(hub, hostID, scope) }
            let answer: Result<HubSession, DeviceHubError>
            do { answer = .success(try await call.value) } catch {
                answer = .failure(error as? DeviceHubError ?? .transport("\(error)"))
            }
            guard let self, !Task.isCancelled else {
                // Cancelled (closed, asked again) or the viewer is gone: the session this request
                // made is nobody's, unless a ticket already started it here. End it, so the Mac
                // drops its prompt and no unwatched session goes live.
                if case let .success(session) = answer, self?.sessionID != session.id {
                    sessionLeft(session.id)
                    await endSession(hub, session.id, ScreenSharingEndReason.viewerDisconnected.rawValue)
                }
                return
            }
            requestAnswered(answer, scope: scope)
        }
    }

    /// The hub's answer to `request(_:)` (tests call it directly).
    func requestAnswered(_ answer: Result<HubSession, DeviceHubError>, scope: SessionScope) {
        guard case .requesting = phase else {
            // The ticket push came before the HTTP answer: it already moved on. Any other
            // session the answer names is nobody's (a ticket for another session started first).
            if case let .success(session) = answer, session.id != sessionID {
                end(session.id, reason: ScreenSharingEndReason.viewerDisconnected.rawValue)
            }
            return
        }
        switch answer {
        case let .success(session):
            if let early = earlyOutcomes.removeValue(forKey: session.id) {
                phase = early
                return
            }
            if let ticket = hub.tickets[session.id] {
                accept(ticket)
                return
            }
            switch session.state {
            case .pending?: phase = .waitingForApproval(sessionID: session.id, scope: scope)
            case .ended?: phase = .ended(reason: nil)
            case .approved?, .live?, nil: phase = .approved(sessionID: session.id, scope: session.scope ?? scope)
            }
        case let .failure(error):
            phase = .refused(ScreenSharingRefusal(error), requested: scope)
        }
    }

    /// Cancel, Disconnect or the screen closed: the session ends on both sides
    /// (the hub hears the reason first, then the stream stops).
    public func close(reason: ScreenSharingEndReason) {
        let id = sessionID
        cancelPending(endingSession: false)
        phase = .ended(reason: reason.rawValue)
        if let id { end(id, reason: reason.rawValue) }
        stopStream()
        earlyOutcomes = [:]
    }

    // MARK: Pushes

    /// Whether a `session.ticket` names this viewer's request: its session, or
    /// (before the request's answer) its host.
    func accepts(_ ticket: SessionTicket) -> Bool {
        guard ticket.role == .viewer else { return false }
        if let id = sessionID { return id == ticket.sessionId }
        if case .requesting = phase { return ticket.peer.id == hostID }
        return false
    }

    /// Approved: the ticket's signaling goes to a new stream.
    func accept(_ ticket: SessionTicket) {
        // A repeated ticket for the stream already running changes nothing.
        if case let .streaming(id, _) = phase, id == ticket.sessionId { return }
        do {
            pendingSignaling = try makeSignaling(ticket, hub)
        } catch {
            end(ticket.sessionId, reason: ScreenSharingEndReason.failed.rawValue)
            phase = .refused(.other, requested: ticket.scope)
            return
        }
        lastScope = ticket.scope
        phase = .streaming(sessionID: ticket.sessionId, scope: ticket.scope)
        let session = ScreenSession(title: hostName, preferences: preferences.screen(for: hostID),
                                    signaling: { [weak self] in self?.takeSignaling() })
        session.reconnectLimit = 0
        stopStream()
        screen = session
        watch(session, sessionID: ticket.sessionId)
        startStream(session)
    }

    /// A dropped stream (WebRTC failed or ended) cannot reconnect: its ticket admitted once.
    /// End the hub session so the Mac stops sharing, and show the ended card, whose Connect
    /// Again asks the Mac again.
    private func watch(_ session: ScreenSession, sessionID: String) {
        withObservationTracking {
            _ = session.phase
        } onChange: { [weak self, weak session] in
            // task-owner: hops the observation change to the main actor; re-arms on the next change
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.screen === session else { return }
                switch session.phase {
                case .failed, .ended:
                    self.streamDropped(sessionID)
                case .connecting, .connected:
                    self.watch(session, sessionID: sessionID)
                }
            }
        }
    }

    func streamDropped(_ id: String) {
        guard case .streaming(id, _) = phase else { return }
        end(id, reason: ScreenSharingEndReason.failed.rawValue)
        stopStream()
        phase = .ended(reason: ScreenSharingEndReason.failed.rawValue)
        droppedSessionID = id
    }

    /// The session whose stream dropped here last: the Mac's own end reason
    /// (stopped, sharing off, revoked) often arrives a moment after its stream ends.
    @ObservationIgnored private(set) var droppedSessionID: String?

    /// The hub's reason for the dropped session: the ended card says it instead of "failed".
    func droppedReason(_ reason: String?) {
        guard case .ended(ScreenSharingEndReason.failed.rawValue?) = phase, let reason,
              reason != ScreenSharingEndReason.failed.rawValue else { return }
        phase = .ended(reason: reason)
    }

    /// `session.denied`.
    func denied() {
        let scope: SessionScope
        switch phase {
        case let .waitingForApproval(_, requested), let .approved(_, requested), let .requesting(requested): scope = requested
        default: scope = lastScope
        }
        cancelPending(endingSession: false)
        stopStream()
        phase = .declined(scope)
    }

    /// `session.revoked` or `session.ended`: stop now and say why.
    func ended(reason: String?) {
        cancelPending(endingSession: false)
        stopStream()
        phase = .ended(reason: reason)
    }

    /// A denial or end for a session this viewer has no id for yet: while its request's
    /// HTTP answer is out, keep it for that answer (session ids are unique).
    func earlyPush(sessionID: String, denied: Bool, reason: String?) {
        guard case let .requesting(scope) = phase else { return }
        earlyOutcomes[sessionID] = denied ? .declined(scope) : .ended(reason: reason)
    }

    // MARK: Internals

    /// The signaling for `ScreenSession.connect()`: once per ticket.
    func takeSignaling() -> (any ScreenSignaling)? {
        defer { pendingSignaling = nil }
        return pendingSignaling
    }

    private func stopStream() {
        guard let screen else { return }
        preferences.save(screen.preferences, for: hostID)
        screen.close()
        self.screen = nil
    }

    private func cancelPending(endingSession: Bool) {
        requestTask?.cancel()
        requestTask = nil
        pendingSignaling = nil
        if endingSession, let id = sessionID { end(id, reason: ScreenSharingEndReason.viewerDisconnected.rawValue) }
    }

    @discardableResult
    private func end(_ id: String, reason: String) -> Task<Void, Never> {
        sessionLeft(id)
        let end = endSession, hub = hub
        // task-owner: one /end call; the hub's push (or its absence) settles the state
        return Task { await end(hub, id, reason) }
    }
}

/// Why the hub refused a request, as the viewer's card says it.
public enum ScreenSharingRefusal: Equatable, Sendable {
    /// The Mac's permission for this phone is None.
    case permissionNone
    /// An older hub: the permission is View Only and the request was Full Control.
    case viewOnly
    case hostOffline
    /// The Mac does not share its screen.
    case notShared
    case notFound
    case other

    init(_ error: DeviceHubError) {
        switch error.code {
        case .permissionNone?: self = .permissionNone
        case .scopeExceedsPermission?: self = .viewOnly
        case .hostOffline?: self = .hostOffline
        case .notShared?: self = .notShared
        case .notFound?, .deviceRemoved?: self = .notFound
        default: self = .other
        }
    }
}

/// This phone signs its Session DO handshake and its DTLS fingerprints with
/// its device key (the identity the hub registered).
extension DeviceIdentity: @retroactive ScreenTicketSigner {
    public func deviceHeaders(for url: URL) async throws -> [String: String] {
        try DeviceRequestSigner(identity: self).headers(method: "GET", pathAndQuery: DeviceRequestSigner.pathAndQuery(of: url), body: nil)
    }
}

extension DeviceHubICEServer {
    /// The WebRTC form of this ICE server.
    var config: ICEServerConfig { ICEServerConfig(urls: urls, username: username, credential: credential) }
}
#endif
