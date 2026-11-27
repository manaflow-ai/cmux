#if os(iOS)
public import CmuxDeviceHub
public import CmuxMobileBrowserStream
import CmuxMobileTransport
public import CmuxScreenKit
public import Foundation
public import Observation

/// Why a session ended on this phone, as `/end` reasons (PROTOCOL.md, End reasons).
public enum ScreenSharingEndReason: String, Sendable {
    case viewerDisconnected = "viewer_disconnected"
    case signedOut = "signed_out"
    case failed
}

/// A `cmux://mac-screen` link's session: the joined Mac's share host speaks `cmux.rd/1`
/// (it refuses WebRTC offers), on the display the link names, view-only unless it asked for control.
public struct MacScreenRdTarget: Equatable, Sendable {
    /// The link's `CGDirectDisplayID`; nil streams the Mac's main display.
    public var displayID: UInt32?
    public var control: Bool

    public init(displayID: UInt32?, control: Bool) {
        self.displayID = displayID
        self.control = control
    }
}

/// One Screen Sharing session from this phone to a Mac, as the viewer: it
/// asks the hub for a session, waits for the Mac's approval and ticket, and
/// keeps the approved session alive across a transient stream drop. A drop
/// re-admits this same viewer/host pair with a short-lived ticket.
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
        /// The stream failed; the approved hub session is being re-admitted.
        case reconnecting(sessionID: String, scope: SessionScope)
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
    public private(set) var phase: Phase = .idle {
        didSet { phaseChanged() }
    }
    /// Whether this viewer went full screen: once the Mac was asked, approved or streaming. A
    /// request from the list stays in the list until then (its row spins), and a refusal
    /// before then is the list's alert, never a full-screen card (user 2026-11-13).
    public private(set) var shown = false
    /// The stream while approved (nil before the ticket and after the end).
    public private(set) var screen: ScreenSession?
    public private(set) var lastScope: SessionScope = .full
    /// Set: this session streams over `cmux.rd/1`, not WebRTC: a `cmux://mac-screen` link, a
    /// Linux desktop, or a Mac whose share host answered WebRTC with cmux.rd/1 (its app is
    /// closed and its acpmux daemon serves the phone, ``hostServes(_:sessionID:)``).
    @ObservationIgnored var rd: MacScreenRdTarget?
    /// The `cmux.rd/1` stream while approved (``rd`` set), instead of ``screen``.
    public private(set) var rdScreen: StreamedBrowserModel?
    /// Whether ``rdScreen`` sends this phone's touches and keys (control asked and granted).
    public private(set) var rdControl = false
    /// The ticket's signaling for the next `cmux.rd/1` open: once per ticket.
    @ObservationIgnored private var pendingRd: MacScreenRdPending?

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
    /// Re-admits the same approved session after a transient stream drop.
    @ObservationIgnored var reattachSession: @MainActor (DeviceHub, String) async throws -> SessionTicket = { hub, id in
        try await hub.reattachSession(id)
    }
    /// The hub refused before this viewer went full screen (the service shows the alert).
    @ObservationIgnored var refusedBeforeShown: @MainActor (ScreenSharingRefusal, SessionScope) -> Void = { _, _ in }
    /// Starts the stream (tests replace it: no WebRTC there).
    @ObservationIgnored var startStream: @MainActor (ScreenSession) -> Void = { $0.connect() }
    /// Every session this viewer ended or left on the hub (the service ignores later tickets for them).
    @ObservationIgnored var sessionLeft: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored private var pendingSignaling: (any ScreenSignaling)?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var reattachTask: Task<Void, Never>?
    /// A denial or end the hub pushed before the request's HTTP answer named its session.
    @ObservationIgnored private var earlyOutcomes: [String: Phase] = [:]

    /// `hostPlatform`: a Linux desktop serves `cmux.rd/1` viewers only, so its sessions open
    /// cmux.rd/1 from the start (control with a Full Control grant); a Mac starts on WebRTC.
    init(hostID: String, hostName: String, hostPlatform: DevicePlatform? = nil, hub: DeviceHub,
         preferences: ScreenSharingPreferences) {
        self.hostID = hostID
        self.hostName = hostName
        self.hub = hub
        self.preferences = preferences
        if Self.servesRdOnly(hostPlatform) { rd = MacScreenRdTarget(displayID: nil, control: true) }
    }

    /// Whether a host of `platform` serves `cmux.rd/1` viewers only (its host refuses WebRTC).
    /// Exhaustive, so a new platform says which it speaks.
    nonisolated static func servesRdOnly(_ platform: DevicePlatform?) -> Bool {
        switch platform {
        case .linux?, .windows?: true
        case .macos?, .ios?, nil: false
        }
    }

    private func phaseChanged() {
        if phase.goesFullScreen {
            shown = true
        } else if case let .refused(refusal, requested) = phase, !shown {
            refusedBeforeShown(refusal, requested)
        }
    }

    /// The session id the hub knows this viewer by, once it answered.
    public var sessionID: String? {
        switch phase {
        case let .waitingForApproval(id, _), let .approved(id, _), let .streaming(id, _), let .reconnecting(id, _): id
        default: nil
        }
    }

    /// Whether a request or stream is in progress (the waiting card or the screen shows).
    public var isActive: Bool {
        switch phase {
        case .requesting, .waitingForApproval, .approved, .streaming, .reconnecting: true
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
        reattachTask?.cancel()
        reattachTask = nil
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
            case .approved?, .live?, nil:
                phase = .approved(sessionID: session.id, scope: session.scope ?? scope)
                scheduleTicketWait(session.id)
            }
        case let .failure(error):
            phase = .refused(ScreenSharingRefusal(error), requested: scope)
        }
    }

    /// How long an approved session waits for its `session.ticket` push before asking the hub for it.
    @ObservationIgnored var ticketWait: Duration = .seconds(8)

    /// Approved, and the ticket never came: pushes have no backlog, so a ticket pushed while the
    /// hub socket was down is gone and the screen said Connecting forever. Past the wait the
    /// ticket is asked for directly (`/reattach` re-admits an approved session); if the hub has
    /// none either, the screen says why, with Try Again.
    private func scheduleTicketWait(_ id: String) {
        reattachTask?.cancel()
        let hub = hub, reattach = reattachSession, wait = ticketWait
        reattachTask = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, case let .approved(current, scope) = self.phase, current == id else { return }
            let answer: Result<SessionTicket, DeviceHubError>
            do { answer = .success(try await reattach(hub, id)) } catch {
                answer = .failure(error as? DeviceHubError ?? .transport("\(error)"))
            }
            guard !Task.isCancelled, case .approved(id, _) = self.phase else { return }
            switch answer {
            case let .success(ticket):
                self.accept(ticket)
            case let .failure(error):
                self.end(id, reason: ScreenSharingEndReason.failed.rawValue)
                self.phase = .refused(ScreenSharingRefusal(error), requested: scope)
            }
        }
    }

    /// Cancel, Disconnect or the screen closed: the session ends on both sides
    /// (the hub hears the reason first, then the stream stops).
    public func close(reason: ScreenSharingEndReason) {
        let id = sessionID
        reattachTask?.cancel()
        reattachTask = nil
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
            if case let .reconnecting(id, _) = phase, id == ticket.sessionId {
                scheduleReattach(ticket.sessionId)
                return
            }
            end(ticket.sessionId, reason: ScreenSharingEndReason.failed.rawValue)
            phase = .refused(.other(reason: ScreenSharingRefusal.reason(error as? DeviceHubError ?? .transport(error.localizedDescription))),
                             requested: ticket.scope)
            return
        }
        lastScope = ticket.scope
        phase = .streaming(sessionID: ticket.sessionId, scope: ticket.scope)
        reattachTask?.cancel()
        reattachTask = nil
        if rd == nil, let signaling = pendingSignaling as? any ScreenHostTransportSignaling {
            // A Mac whose app is closed: its acpmux daemon serves this phone over cmux.rd/1, and
            // says so in answer to the WebRTC offer (cmuxterm-hq#18912).
            let id = ticket.sessionId
            signaling.onHostTransport { [weak self] transport in
                // task-owner: hops one host frame to the main actor
                Task { @MainActor [weak self] in self?.hostServes(transport, sessionID: id) }
            }
        }
        if let rd {
            acceptRd(ticket, target: rd)
            return
        }
        if let screen {
            screen.reconnect()
            watch(screen, sessionID: ticket.sessionId)
            return
        }
        let session = ScreenSession(title: hostName, preferences: preferences.screen(for: hostID),
                                    signaling: { [weak self] in self?.takeSignaling() })
        session.reconnectLimit = 0
        session.vncRules = ScreenSharingVNCRules.rules
        // Follow mode: the Follow button shows once the Mac sends focus signals.
        ScreenSharingFollowCamera().attach(to: session)
        // A drop goes straight to the reattach (no failed card first, over the last frame).
        session.onDropped = { [weak self, weak session] in
            // Taken only while this viewer streams this screen's session: then it reattaches.
            guard let self, let session, self.screen === session, let id = self.sessionID,
                  case let .streaming(current, _) = self.phase, current == id else { return false }
            self.streamDropped(id)
            return true
        }
        stopStream()
        screen = session
        watch(session, sessionID: ticket.sessionId)
        startStream(session)
    }

    /// A dropped stream leaves the approved hub session alive and asks for a
    /// fresh viewer/host ticket using the fixed roaming backoff.
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
                case .connected:
                    // A stream that came up: its next drop starts the backoff over (first try at once).
                    self.reattachAttempts = 0
                    self.watch(session, sessionID: sessionID)
                case .connecting:
                    self.watch(session, sessionID: sessionID)
                }
            }
        }
    }

    // MARK: cmux.rd/1

    /// Approved for a `cmux.rd/1` session: the ticket's signaling goes to the next open of the
    /// streamed-surface model (a new one, or the dropped one opening again).
    private func acceptRd(_ ticket: SessionTicket, target: MacScreenRdTarget) {
        guard let signaling = takeSignaling() else { return }
        pendingRd = MacScreenRdPending(signaling: signaling, sessionID: ticket.sessionId)
        // A view-scope grant never sends input, whatever the link asked.
        let control = target.control && ticket.scope == .full
        // A reattach reuses the model only while the grant is the same: a ticket that narrows the
        // scope gets a new view-only model, never the old control surface.
        if let rdScreen, rdControl == control {
            rdScreen.reconnect()
            return
        }
        let signalingKept = pendingRd
        let displayID = target.displayID
        let model = StreamedBrowserModel(tab: "mac-screen", url: nil) { [weak self] sink, _, _ in
            try await Self.openRd(self, sink: sink, control: control, displayID: displayID)
        }
        stopStream()
        pendingRd = signalingKept
        rdControl = control
        rdScreen = model
    }

    #if canImport(CmuxMobileLinkFFI)
    private nonisolated static func openRd(_ viewer: ScreenSharingViewer?, sink: any BrowserStreamSink, control: Bool,
                                           displayID: UInt32?) async throws -> any BrowserStreamConnection {
        guard let pending = await viewer?.takeRd() else { throw MacScreenRdOpenError.noTicket }
        let sessionID = pending.sessionID
        let watched = MacScreenRdSink(sink) { [weak viewer] code, reason in
            viewer?.rdClosed(sessionID: sessionID, code: code, reason: reason)
        }
        let connection = try MacScreenRdConnection(control: control, signaling: pending.signaling,
                                                   sessionID: sessionID, displayID: displayID)
        connection.start(sink: watched)
        return connection
    }
    #else
    private nonisolated static func openRd(_ viewer: ScreenSharingViewer?, sink: any BrowserStreamSink, control: Bool,
                                           displayID: UInt32?) async throws -> any BrowserStreamConnection {
        throw MacScreenRdOpenError.unsupported
    }
    #endif

    /// The model opens: the current ticket's signaling, once. An open with none (the model's own
    /// stall reconnect) asks the hub for a fresh ticket instead.
    private func takeRd() -> MacScreenRdPending? {
        defer { pendingRd = nil }
        if pendingRd == nil, let id = sessionID { streamDropped(id) }
        return pendingRd
    }

    /// The host answered this viewer's WebRTC offer with the protocol it serves: `cmux.rd/1`
    /// from a Mac whose app is closed (its acpmux daemon serves the share) or a Linux desktop.
    /// The WebRTC stream goes, and the session reattaches (a fresh ticket, at once) and opens
    /// cmux.rd/1 from then on, in control with a Full Control grant (taps are the host's clicks).
    func hostServes(_ transport: String, sessionID id: String) {
        guard transport == TicketSignaling.rdTransport, rd == nil, case .streaming(id, _) = phase else { return }
        rd = MacScreenRdTarget(displayID: nil, control: true)
        streamDropped(id)
        stopStream()
    }

    /// The `cmux.rd/1` stream closed: the host's end or refusal ends the session; a link that
    /// failed or closed reattaches like a dropped WebRTC stream.
    func rdClosed(sessionID id: String, code: String, reason: String) {
        guard rdScreen != nil, sessionID == id else { return }
        switch code {
        case "ended":
            // The Mac ended it: the hub hears that from the Mac.
            ended(reason: reason.isEmpty ? code : reason)
        case "refused":
            end(id, reason: ScreenSharingEndReason.failed.rawValue)
            ended(reason: reason.isEmpty ? code : reason)
        default:
            streamDropped(id)
        }
    }

    func streamDropped(_ id: String) {
        guard case let .streaming(current, scope) = phase, current == id else { return }
        screen?.prepareForReconnect()
        phase = .reconnecting(sessionID: id, scope: scope)
        droppedSessionID = id
        scheduleReattach(id)
    }

    /// The first try goes at once (the drop is already known and the hub answers in one round
    /// trip), then the link's roaming backoff: 1/2/4/8/16/30 seconds, then 30 seconds.
    public nonisolated static let reattachBackoff: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                                                                 .seconds(16), .seconds(30)]

    /// The app came back to the foreground (or the network came back): a reattach waiting out
    /// a long backoff step tries again now, from the start of the backoff. A reattach call
    /// already waiting on the hub is left to answer.
    public func reattachNow() {
        guard case let .reconnecting(id, _) = phase, !reattachInFlight else { return }
        reattachAttempts = 0
        scheduleReattach(id)
    }

    /// Reattach tries since the stream last came up: kept across tickets, so a stream that fails
    /// again before it connects (or a ticket whose signaling can't start) backs off instead of
    /// asking the hub again at once, over and over.
    @ObservationIgnored private var reattachAttempts = 0
    /// A reattach call is waiting on the hub's answer.
    @ObservationIgnored private var reattachInFlight = false

    /// The next backoff step, counting the try.
    private func nextReattachDelay() -> Duration {
        defer { reattachAttempts += 1 }
        return Self.reattachBackoff[min(reattachAttempts, Self.reattachBackoff.count - 1)]
    }

    private func scheduleReattach(_ id: String) {
        reattachTask?.cancel()
        reattachInFlight = false
        let hub = hub
        let reattach = reattachSession
        reattachTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextReattachDelay() else { return }
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, case .reconnecting(id, _) = self.phase else { return }
                self.reattachInFlight = true
                do {
                    let ticket = try await reattach(hub, id)
                    guard !Task.isCancelled else { return } // a newer schedule owns the flag now
                    self.reattachInFlight = false
                    self.accept(ticket)
                    return
                } catch {
                    if !Task.isCancelled { self.reattachInFlight = false }
                }
            }
        }
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
        case let .waitingForApproval(_, requested), let .approved(_, requested), let .requesting(requested), let .reconnecting(_, requested): scope = requested
        default: scope = lastScope
        }
        cancelPending(endingSession: false)
        stopStream()
        phase = .declined(scope)
    }

    /// `session.revoked` or `session.ended`: stop now and say why.
    func ended(reason: String?) {
        reattachTask?.cancel()
        reattachTask = nil
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
        pendingRd = nil
        if let rdScreen {
            rdScreen.close()
            self.rdScreen = nil
        }
        guard let screen else { return }
        preferences.save(screen.preferences, for: hostID)
        screen.close()
        self.screen = nil
    }

    private func cancelPending(endingSession: Bool) {
        requestTask?.cancel()
        requestTask = nil
        pendingSignaling = nil
        pendingRd = nil
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

extension ScreenSharingViewer.Phase {
    /// Past asking the hub: the Mac was asked, approved, streaming, or it said no or ended.
    var goesFullScreen: Bool {
        switch self {
        case .idle, .requesting, .refused: false
        case .waitingForApproval, .approved, .streaming, .reconnecting, .declined, .ended: true
        }
    }

    var isRequesting: Bool { if case .requesting = self { true } else { false } }
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
    /// Anything else (a transport failure, a server error, a code this build does not know),
    /// with the hub's own words when it gave any: the card says them.
    case other(reason: String?)

    init(_ error: DeviceHubError) {
        switch error.code {
        case .permissionNone?: self = .permissionNone
        case .scopeExceedsPermission?: self = .viewOnly
        case .hostOffline?: self = .hostOffline
        case .notShared?: self = .notShared
        case .notFound?, .deviceRemoved?: self = .notFound
        default: self = .other(reason: Self.reason(error))
        }
    }

    /// Whether this is a refusal without a card of its own (``other(reason:)``).
    var isOther: Bool { if case .other = self { true } else { false } }

    /// The hub's words for a refusal this build has no card of its own for: the server's
    /// message (else its code), the HTTP status, or the transport's own error; nil when
    /// there is nothing to say.
    static func reason(_ error: DeviceHubError) -> String? {
        let text: String = switch error {
        case let .server(_, code, message): message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? code.rawValue : message
        case let .http(status): "HTTP \(status)"
        case let .transport(detail), let .decoding(detail), let .identity(detail): detail
        case .notConfigured, .notSignedIn: ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
/// A ticket's signaling waiting for the `cmux.rd/1` open.
struct MacScreenRdPending: Sendable {
    let signaling: any ScreenSignaling
    let sessionID: String
}

enum MacScreenRdOpenError: Error, CustomStringConvertible {
    case noTicket
    case unsupported

    var description: String {
        switch self {
        case .noTicket: String(localized: "Reconnecting to the Mac…")
        case .unsupported: String(localized: "This build can't show a Mac's screen.")
        }
    }
}

/// Passes a `cmux.rd/1` stream to the model and tells the viewer how it closed.
final class MacScreenRdSink: BrowserStreamSink, Sendable {
    private let inner: any BrowserStreamSink
    private let closed: @MainActor @Sendable (String, String) -> Void

    init(_ inner: any BrowserStreamSink, closed: @escaping @MainActor @Sendable (String, String) -> Void) {
        self.inner = inner
        self.closed = closed
    }

    func browserFrame(_ frame: BrowserStreamFrame) { inner.browserFrame(frame) }
    func browserMessage(_ json: Data) { inner.browserMessage(json) }

    func browserClosed(code: String, reason: String) {
        inner.browserClosed(code: code, reason: reason)
        let closed = closed
        // task-owner: hops one close to the main actor
        Task { @MainActor in closed(code, reason) }
    }
}
#endif
