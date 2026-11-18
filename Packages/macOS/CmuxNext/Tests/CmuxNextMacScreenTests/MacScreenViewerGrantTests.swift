import CmuxNextCompat
import CmuxNextDevices
import CmuxScreenKit
import CryptoKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

nonisolated private let hostID = "6f1c2a7e-0b1d-4c55-9a63-2f1e7d9b8a10"
nonisolated private let viewerID = "0d4b9e21-77aa-4f0e-8c3b-5a6d1e2f3c40"

/// One side of a hub session socket. Grant frames go to the other side's handler through `relay`
/// (the Session DO), which a test may rewrite in transit; screen signals come in through `feed`.
nonisolated final class GrantTestSocket: MacScreenGrantChannel, Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var relay: (@Sendable (String) -> Void)?
        var sent: [ScreenSignal] = []
        var closed = false
    }

    private let state = Mutex(State())
    private let incoming: AsyncThrowingStream<ScreenSignal, any Error>
    let feed: AsyncThrowingStream<ScreenSignal, any Error>.Continuation

    init() { (incoming, feed) = AsyncThrowingStream.makeStream(of: ScreenSignal.self) }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { incoming }
    func send(_ signal: ScreenSignal) async throws { state.withLock { $0.sent.append(signal) } }
    func iceServers() async throws -> [ICEServerConfig] { [] }
    func close() {
        state.withLock { $0.closed = true }
        feed.finish()
    }
    var endsSessionOnClose: Bool { true }
    func setGrantHandler(_ handler: (@Sendable (String) -> Void)?) { state.withLock { $0.handler = handler } }
    func sendGrantFrame(_ text: String) async throws { state.withLock { $0.relay }?(text) }

    func relay(to peer: GrantTestSocket, rewrite: @escaping @Sendable (String) -> String = { $0 }) {
        state.withLock { $0.relay = { [weak peer] text in peer?.deliver(rewrite(text)) } }
    }
    func deliver(_ text: String) { state.withLock { $0.handler }?(text) }
    var sent: [ScreenSignal] { state.withLock { $0.sent } }
    var closed: Bool { state.withLock { $0.closed } }
}

/// acpmux's two person-line calls, as `viewer_grant_host.rs` answers them (the Rust tests hold the
/// real rules): a one-time challenge per session, a key registered on its first signed proof, and a
/// proof admitted only for this host, the ticket's viewer and session, the fresh challenge and the key.
@MainActor final class GrantTestAcpmux {
    var keys: [String: P256.Signing.PublicKey] = [:]
    var challenges: [String: String] = [:]
    var calls: [String] = []

    var gate: MacScreenViewerGrantGate {
        MacScreenViewerGrantGate(host: { hostID }, call: { [self] method, params in call(method, params) })
    }

    func call(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        calls.append(method)
        let text = { (key: String) in params[key] as? String ?? "" }
        let (session, viewer) = (text("session"), text("viewer"))
        if method == "_acpmux/viewer_grant_challenge" {
            let challenge = UUID().uuidString
            challenges[session] = challenge
            return ["challenge": challenge, "granted": keys[viewer] != nil]
        }
        guard method == "_acpmux/viewer_grant_admit", let proof = params["proof"] as? [String: String],
              let challenge = challenges.removeValue(forKey: session) else { return ["admitted": false] }
        var key = keys[viewer]
        if let registration = params["registration"] as? [String: String], registration["viewer"] == viewer,
           registration["host"] == hostID, let data = Data(base64Encoded: registration["key"] ?? "") {
            key = try? P256.Signing.PublicKey(x963Representation: data)
        }
        let expected = ViewerGrantProof(host: hostID, viewer: viewer, scope: .view, session: session, challenge: challenge)
        guard let key, text("host") == hostID, text("scope") == "view",
              proof["host"] == hostID, proof["viewer"] == viewer, proof["session"] == session, proof["challenge"] == challenge,
              proof["scope"] == "view", let raw = Data(base64Encoded: proof["signature"] ?? ""),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(signature, for: Data(expected.canonical.utf8)) else { return ["admitted": false] }
        keys[viewer] = key
        return ["admitted": true]
    }
}

/// The viewer's answer with a software key in place of the Secure Enclave one (no Touch ID on CI).
nonisolated private func answer(with key: P256.Signing.PrivateKey, register: Bool) -> MacScreenGrantAnswer {
    { ticket, frame in
        guard let challenge = MacScreenGrantFrame.fields(frame)?["challenge"] as? String,
              let proof = try? ViewerGrantProof(host: ticket.peer.id, viewer: viewerID, scope: .view, session: ticket.sessionId,
                                                challenge: challenge).signed(with: { try key.signature(for: $0).rawRepresentation })
        else { return nil }
        let registration = register
            ? ["host": ticket.peer.id, "viewer": viewerID, "scope": "view", "key": key.publicKey.x963Representation.base64EncodedString()]
            : nil
        return MacScreenGrantFrame.proof(proof, registration: registration)
    }
}

private func ticket(_ session: String, role: SessionTicket.Role) -> SessionTicket {
    SessionTicket(sessionId: session, ticket: "a.b.c", signalURL: URL(string: "wss://hub.invalid/v1/sessions/\(session)/ws")!, ice: [],
                  peer: .init(id: role == .host ? viewerID : hostID, name: "Studio", signingKey: "key"), role: role, scope: .view)
}

/// A frame the viewer sent, kept as it crossed the relay.
nonisolated final class GrantTestCaptured: Sendable {
    let frame = Mutex<String?>(nil)
}

@Suite @MainActor struct MacScreenViewerGrantTests {
    struct Run {
        let host: GrantTestSocket
        let gated: MacScreenGrantGatedSignaling
        let got: [ScreenSignal]
    }

    /// One session: the host's ticket was refused by its consent and serves gated; the viewer answers.
    /// The host's side signals `hello` and the viewer's offer; `got` is what the screen path received.
    func run(_ session: String, acpmux: GrantTestAcpmux, answer: @escaping MacScreenGrantAnswer,
             rewrite: @escaping @Sendable (String) -> String = { $0 }) async throws -> Run {
        let (host, viewer) = (GrantTestSocket(), GrantTestSocket())
        host.relay(to: viewer)
        viewer.relay(to: host, rewrite: rewrite)
        let gated = MacScreenGrantGatedSignaling(inner: host, ticket: ticket(session, role: .host), gate: acpmux.gate, timeout: .seconds(10))
        let answering = MacScreenGrantAnsweringSignaling(inner: viewer, ticket: ticket(session, role: .viewer), answer: answer)
        let stream = gated.messages()
        try await gated.send(.answer("held back"))
        host.feed.yield(.hello(peerPresent: true))
        host.feed.yield(.offer("v=0 offer"))
        var got: [ScreenSignal] = []
        for try await signal in stream {
            got.append(signal)
            if got.count == 2 || signal == .bye { break }
        }
        withExtendedLifetime(answering) {}
        return Run(host: host, gated: gated, got: got)
    }

    @Test func aGenuineGrantServesAndNothingLeavesBeforeIt() async throws {
        let acpmux = GrantTestAcpmux()
        let key = P256.Signing.PrivateKey()
        let first = try await run("s1", acpmux: acpmux, answer: answer(with: key, register: true))
        #expect(first.got == [.hello(peerPresent: true), .offer("v=0 offer")])
        #expect(first.gated.admitted == true)
        // The host's answer sent before admission never left; one after it does.
        #expect(first.host.sent.isEmpty)
        try await first.gated.send(.answer("v=0 answer"))
        #expect(first.host.sent == [.answer("v=0 answer")])
        #expect(acpmux.calls == ["_acpmux/viewer_grant_challenge", "_acpmux/viewer_grant_admit"])

        // A later session needs only the proof (Touch ID again on the viewer, nothing on the host).
        let later = try await run("s2", acpmux: acpmux, answer: answer(with: key, register: false))
        #expect(later.got == [.hello(peerPresent: true), .offer("v=0 offer")])
    }

    @Test func theHostRefusesAForgedGrantEndToEnd() async throws {
        let acpmux = GrantTestAcpmux()
        let genuine = P256.Signing.PrivateKey()
        _ = try await run("s1", acpmux: acpmux, answer: answer(with: genuine, register: true))
        let registered = acpmux.keys

        // Another key signs, without a registration and with the genuine key's registration in transit.
        for register in [false, true] {
            let forger = P256.Signing.PrivateKey()
            let rewrite: @Sendable (String) -> String = { text in
                guard register, var fields = MacScreenGrantFrame.fields(text) else { return text }
                fields["registration"] = ["host": hostID, "viewer": viewerID, "scope": "view",
                                          "key": genuine.publicKey.x963Representation.base64EncodedString()]
                let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
            let forged = try await run("f\(register)", acpmux: acpmux, answer: answer(with: forger, register: false), rewrite: rewrite)
            #expect(forged.got == [.bye])
            #expect(forged.gated.admitted == false)
            #expect(forged.host.sent == [.bye])
            #expect(forged.host.closed)
        }
        #expect(acpmux.keys.mapValues(\.rawRepresentation) == registered.mapValues(\.rawRepresentation))
    }

    @Test func theHostRefusesACopiedGrantEndToEnd() async throws {
        let acpmux = GrantTestAcpmux()
        let key = P256.Signing.PrivateKey()
        let captured = GrantTestCaptured()
        let genuine = try await run("s1", acpmux: acpmux, answer: answer(with: key, register: true)) { text in
            captured.frame.withLock { $0 = text }
            return text
        }
        #expect(genuine.gated.admitted == true)
        let copy = try #require(captured.frame.withLock { $0 })

        // The s1 proof, replayed on a new session: its session and challenge are not this one's.
        let copied = try await run("s2", acpmux: acpmux, answer: answer(with: key, register: false)) { _ in copy }
        #expect(copied.got == [.bye])
        #expect(copied.gated.admitted == false)
        #expect(copied.host.sent == [.bye])
    }

    @Test func noProofEndsTheSessionUnserved() async throws {
        let acpmux = GrantTestAcpmux()
        let silent: MacScreenGrantAnswer = { _, _ in nil }
        let (host, viewer) = (GrantTestSocket(), GrantTestSocket())
        host.relay(to: viewer)
        viewer.relay(to: host)
        let gated = MacScreenGrantGatedSignaling(inner: host, ticket: ticket("s1", role: .host), gate: acpmux.gate, timeout: .milliseconds(200))
        let answering = MacScreenGrantAnsweringSignaling(inner: viewer, ticket: ticket("s1", role: .viewer), answer: silent)
        let stream = gated.messages()
        host.feed.yield(.hello(peerPresent: true))
        var got: [ScreenSignal] = []
        for try await signal in stream { got.append(signal) }
        withExtendedLifetime(answering) {}
        #expect(got == [.bye])
        #expect(acpmux.calls == ["_acpmux/viewer_grant_challenge"])
    }
}
