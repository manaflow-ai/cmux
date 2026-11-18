public import CmuxNextDevices
import CmuxNextCompat
public import CmuxScreenKit
import Foundation

/// A viewer's Touch ID grant for a Mac whose machine-join consent has not granted screen (or
/// control) to its signed-in machines (CMUX-572). Leo: "be better than macOS screensharing
/// permissions ... u can make touch ID?". The rules and the check are acpmux's
/// (`viewer_grant.rs`, `viewer_grant_host.rs`); this is only the transport over the session's
/// signaling (the hub's authenticated device channel; the Session DO relays the two frame types).
///
/// The host, instead of refusing such a ticket, serves it gated (``MacScreenGrantGatedSignaling``):
/// it sends `grant-challenge`, holds every screen signal, and passes them on only after acpmux
/// admitted the viewer's `grant-proof`. The viewer (``MacScreenGrantAnsweringSignaling``) answers
/// the challenge with its Secure Enclave key, which asks Touch ID or the login password.
public nonisolated struct MacScreenViewerGrantGate: Sendable {
    /// `_acpmux/viewer_grant_challenge` for the ticket: the challenge, or nil when this Mac cannot ask.
    public var challenge: @MainActor @Sendable (SessionTicket) async -> String?
    /// `_acpmux/viewer_grant_admit` with the viewer's `grant-proof` frame (JSON text): whether to serve.
    public var admit: @MainActor @Sendable (SessionTicket, String) async -> Bool

    public init(challenge: @escaping @MainActor @Sendable (SessionTicket) async -> String?,
                admit: @escaping @MainActor @Sendable (SessionTicket, String) async -> Bool) {
        self.challenge = challenge
        self.admit = admit
    }

    /// The scope word the grant frames and acpmux use for a ticket's scope.
    nonisolated static func scope(_ scope: SessionScope) -> String { scope == .full ? "control" : "view" }
}

/// A signaling that also carries the grant frames: ``TicketSignaling`` (the hub's session socket); tests fake it.
public nonisolated protocol MacScreenGrantChannel: ScreenSignaling {
    /// Where the peer's grant frames (JSON text) go.
    func setGrantHandler(_ handler: (@Sendable (String) -> Void)?)
    /// Sends one grant frame to the peer.
    func sendGrantFrame(_ text: String) async throws
}

nonisolated extension TicketSignaling: MacScreenGrantChannel {}

/// What a viewer signs a challenge with: its proof frame for the challenge frame, or nil (no
/// Touch ID, cancelled, no enclave).
public typealias MacScreenGrantAnswer = @Sendable (_ ticket: SessionTicket, _ challengeFrame: String) async -> String?

/// The frames, as JSON text.
nonisolated enum MacScreenGrantFrame {
    static func challenge(_ challenge: String, scope: SessionScope) -> String {
        json(["type": "grant-challenge", "challenge": challenge, "scope": MacScreenViewerGrantGate.scope(scope)])
    }

    static func proof(_ proof: ViewerGrantProof, registration: [String: String]?) -> String {
        var frame: [String: Any] = ["type": "grant-proof", "proof": proof.json]
        if let registration { frame["registration"] = registration }
        return json(frame)
    }

    static func fields(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The host's signaling for a gated ticket: every screen signal waits until acpmux admits the
/// viewer's proof; a refusal, no proof within ``proofTimeout`` or no challenge ends it with `bye`.
public nonisolated final class MacScreenGrantGatedSignaling: ScreenSignaling, Sendable {
    public nonisolated static let proofTimeout: Duration = .seconds(60)

    private struct State: Sendable {
        var admitted: Bool?
        var held: [ScreenSignal] = []
        var out: AsyncThrowingStream<ScreenSignal, any Error>.Continuation?
    }

    let inner: any MacScreenGrantChannel
    let ticket: SessionTicket
    let gate: MacScreenViewerGrantGate
    let timeout: Duration
    private let state = Mutex(State())

    public init(inner: any MacScreenGrantChannel, ticket: SessionTicket, gate: MacScreenViewerGrantGate, timeout: Duration = proofTimeout) {
        self.inner = inner
        self.ticket = ticket
        self.gate = gate
        self.timeout = timeout
    }

    public var endsSessionOnClose: Bool { inner.endsSessionOnClose }
    public func iceServers() async throws -> [ICEServerConfig] { try await inner.iceServers() }
    public func close() { inner.close() }

    public func send(_ signal: ScreenSignal) async throws {
        // Nothing of the host's screen path leaves before the viewer is admitted.
        guard state.withLock({ $0.admitted }) == true else { return }
        try await inner.send(signal)
    }

    /// Whether the viewer was admitted (nil: not decided yet). Tests read it.
    var admitted: Bool? { state.withLock { $0.admitted } }

    public func messages() -> AsyncThrowingStream<ScreenSignal, any Error> {
        let (stream, out) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, bufferingPolicy: .bufferingNewest(256))
        state.withLock { $0.out = out }
        let (proofs, proofSink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        inner.setGrantHandler { text in
            if MacScreenGrantFrame.fields(text)?["type"] as? String == "grant-proof" { proofSink.yield(text) }
        }
        let reader = Task { [self] in
            do {
                var gating: Task<Void, Never>?
                for try await signal in inner.messages() {
                    if case .hello = signal, gating == nil {
                        gating = Task { await self.decide(proofs: proofs, end: proofSink) }
                    }
                    // Under the lock, as the flush: a signal never passes one held before it.
                    state.withLock { state in
                        guard state.admitted == true else {
                            if state.admitted == nil, state.held.count < 256 { state.held.append(signal) }
                            return
                        }
                        out.yield(signal)
                    }
                }
                out.finish()
            } catch { out.finish(throwing: error) }
        }
        out.onTermination = { _ in reader.cancel() }
        return stream
    }

    /// Challenge, wait for the proof, ask acpmux; then let the held signals through or end.
    private func decide(proofs: AsyncStream<String>, end: AsyncStream<String>.Continuation) async {
        guard let challenge = await gate.challenge(ticket) else { return await refuse() }
        do { try await inner.sendGrantFrame(MacScreenGrantFrame.challenge(challenge, scope: ticket.scope)) } catch { return await refuse() }
        let timeout = timeout
        // The deadline ends the proof stream; the proof arriving cancels it.
        let deadline = Task {
            // wakeup-allow: one bounded wait for the viewer's Touch ID answer; the proof arriving cancels it.
            try? await Task.sleep(for: timeout)
            end.finish()
        }
        var iterator = proofs.makeAsyncIterator()
        let proof = await iterator.next()
        deadline.cancel()
        guard let proof, await gate.admit(ticket, proof) else { return await refuse() }
        state.withLock { state in
            state.admitted = true
            for signal in state.held { state.out?.yield(signal) }
            state.held = []
        }
    }

    private func refuse() async {
        let out = state.withLock { state -> AsyncThrowingStream<ScreenSignal, any Error>.Continuation? in
            state.admitted = false
            state.held = []
            return state.out
        }
        try? await inner.send(.bye)
        out?.yield(.bye)
        out?.finish()
        inner.close()
    }
}

/// The viewer's signaling: everything passes through, and a `grant-challenge` from the host is
/// answered with ``MacScreenGrantAnswer`` (Touch ID or the login password on this Mac).
public nonisolated final class MacScreenGrantAnsweringSignaling: ScreenSignaling, Sendable {
    let inner: any MacScreenGrantChannel

    public init(inner: any MacScreenGrantChannel, ticket: SessionTicket, answer: @escaping MacScreenGrantAnswer) {
        self.inner = inner
        inner.setGrantHandler { [inner] text in
            guard MacScreenGrantFrame.fields(text)?["type"] as? String == "grant-challenge" else { return }
            // task-owner: one answer per challenge; the host's timeout bounds it, and the session's end closes the socket.
            Task {
                guard let reply = await answer(ticket, text) else { return }
                try? await inner.sendGrantFrame(reply)
            }
        }
    }

    public var endsSessionOnClose: Bool { inner.endsSessionOnClose }
    public func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { inner.messages() }
    public func send(_ signal: ScreenSignal) async throws { try await inner.send(signal) }
    public func iceServers() async throws -> [ICEServerConfig] { try await inner.iceServers() }
    public func close() { inner.close() }
}

/// The viewer's answer with this Mac's Secure Enclave grant keys: the host's challenge, signed
/// for this ticket's session and scope. A first answer for a host and scope makes the key and
/// carries its registration; acpmux keeps it only when that key signed the proof.
public nonisolated extension ViewerGrantKeys {
    func answer(viewer: String, reason: @escaping @Sendable (String) -> String) -> MacScreenGrantAnswer {
        { ticket, frame in
            guard let fields = MacScreenGrantFrame.fields(frame), let challenge = fields["challenge"] as? String,
                  !challenge.isEmpty else { return nil }
            let scope: ViewerGrantScope = ticket.scope == .full ? .control : .view
            let host = ticket.peer.id
            var registration: [String: String]?
            if !hasKey(host: host, scope: scope) {
                guard let key = try? make(host: host, scope: scope) else { return nil }
                registration = ["host": host, "viewer": viewer, "scope": scope.rawValue, "key": key]
            }
            let unsigned = ViewerGrantProof(host: host, viewer: viewer, scope: scope, session: ticket.sessionId, challenge: challenge)
            guard let proof = try? await sign(unsigned, reason: reason(ticket.peer.name)) else { return nil }
            return MacScreenGrantFrame.proof(proof, registration: registration)
        }
    }
}

public extension MacScreenViewerGrantGate {
    /// The gate over acpmux's person line: `call(method, params)` is one `_acpmux/viewer_grant_*`
    /// call (nil: no answer), `host` this Mac's hub id. The viewer it names is the ticket's, which the
    /// hub authenticated, never one a frame claims.
    init(host: @escaping @MainActor @Sendable () -> String?,
         call: @escaping @MainActor @Sendable (String, [String: Any]) async -> [String: Any]?) {
        self.init(challenge: { ticket in
            guard let host = host() else { return nil }
            return await call("_acpmux/viewer_grant_challenge", Self.params(ticket, host: host))?["challenge"] as? String
        }, admit: { ticket, frame in
            guard let host = host(), let fields = MacScreenGrantFrame.fields(frame), let proof = fields["proof"] else { return false }
            var params = Self.params(ticket, host: host)
            params["proof"] = proof
            if let registration = fields["registration"] { params["registration"] = registration }
            return await call("_acpmux/viewer_grant_admit", params)?["admitted"] as? Bool == true
        })
    }

    nonisolated static func params(_ ticket: SessionTicket, host: String) -> [String: Any] {
        ["host": host, "session": ticket.sessionId, "viewer": ticket.peer.id, "scope": scope(ticket.scope)]
    }
}

nonisolated extension L {
    /// Touch ID's reason when this Mac signs a host's grant challenge ("cmux is trying to …").
    static func grantReason(_ host: String) -> String { String(format: t("macScreen.grant.reason", "view the screen of “%@”"), host) }
}
