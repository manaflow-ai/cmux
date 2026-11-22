import Foundation
import Testing
@testable import CmuxNextAgentPane

/// https://github.com/manaflow-ai/cmux/issues/48636: "Not verified as you. Reconnecting your
/// identity to the agent service…" stood above the composer. The pane showed it at the first
/// refused person proof, before the recovery that usually fixes it had started, and kept it up
/// for good on a NIGHTLY whose daemon was another install's (one that never takes this app's key),
/// reconnecting every chat three times there for nothing. Now recovery is silent, the pane hears
/// of a failure only when recovery gave up, and another install's daemon gets no proof at all.
/// These run the real transport against a stand-in acpmux WebSocket.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentPanePersonProofNoticeTests {
    static let challenged = #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"local","extensions":[],"personChallenge":{"nonce":"n-1","connection":"c-1"}}}}"#
    static let refusal = #"{"code":-32000,"message":"the person proof does not answer this connection's challenge","data":{"reason":"person.proof_refused"}}"#
    static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    /// A daemon socket path this test gave a person key, so the transport sends a proof.
    static func keyedSocketPath() -> String {
        let path = "/tmp/ppn-\(UUID().uuidString.prefix(8))/acpmux.sock"
        _ = AcpmuxPersonKey.spawnKey(for: path)
        return path
    }

    /// Waits (bounded; a test helper) until `condition` holds.
    static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// What the transport told the pane, and the host lookups it asked for.
    @MainActor final class Record {
        var told: [Bool] = []
        var lookups = 0
    }

    /// The `_acpmux/person_prove` frames the stand-in got (JSONSerialization writes the method's
    /// slash as `\/`, so the frame is matched on the method's last part).
    static func proofs(_ server: AcpmuxStandInServer) -> Int {
        server.peers.reduce(0) { $0 + $1.frames.filter { $0.contains("person_prove") }.count }
    }

    @Test func aRefusedProofRecoversWithoutAWordToThePerson() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("initialize", with: Self.challenged)
        server.refuse("_acpmux/person_prove", with: Self.refusal)
        let path = Self.keyedSocketPath()
        let transport = AgentPaneTransport()
        transport.deliver = { _, done in done() }
        transport.personRecoveryDelays = [.milliseconds(1)]
        let record = Record()
        transport.onPersonProofFailed = { record.told.append($0) }
        transport.recoverPersonProof = {
            // The host's lookup gave the daemon the key again: the next connection's proof counts.
            record.lookups += 1
            server.stopRefusing("_acpmux/person_prove")
            server.answer("_acpmux/person_prove", with: #"{"person":true}"#)
            return true
        }
        let connection = AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil, socketPath: path)
        let first = try await transport.open(connection)
        #expect(await transport.send(connection: first, frames: [Self.initialize]) == nil)
        // Refused, recovered, and the connection closed for a new one that proves.
        #expect(await Self.until { record.lookups == 1 && transport.connection == nil }, "the transport never recovered the proof")
        #expect(record.told.isEmpty, "the pane was told of a refusal its recovery fixes: \(record.told)")

        let second = try await transport.open(connection)
        #expect(await transport.send(connection: second, frames: [Self.initialize]) == nil)
        #expect(await Self.until { !record.told.isEmpty }, "the proven connection never cleared the notice")
        #expect(record.told == [false], "a refusal reached the pane: \(record.told)")
        #expect(Self.proofs(server) == 2)
        #expect(record.lookups == 1)
    }

    @Test func thePaneHearsOfItOnlyWhenRecoveryGivesUp() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("initialize", with: Self.challenged)
        server.refuse("_acpmux/person_prove", with: Self.refusal)
        let transport = AgentPaneTransport()
        transport.deliver = { _, done in done() }
        transport.personRecoveryDelays = [.milliseconds(1), .milliseconds(1)]
        let record = Record()
        transport.onPersonProofFailed = { record.told.append($0) }
        // Every lookup fails: the key never reaches the daemon again.
        transport.recoverPersonProof = { record.lookups += 1; return false }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil,
                                                           socketPath: Self.keyedSocketPath()))
        #expect(await transport.send(connection: id, frames: [Self.initialize]) == nil)
        #expect(await Self.until { !record.told.isEmpty }, "a recovery that gave up never told the pane")
        #expect(record.told == [true])
        #expect(record.lookups == 2, "the pane heard of it before every lookup was tried")
        #expect(transport.connection == id, "a recovery that gave up closed the chat's connection")
    }

    @Test func anotherInstallsDaemonGetsNoProofAndNoReconnects() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("initialize", with: Self.challenged)
        server.refuse("_acpmux/person_prove", with: Self.refusal)
        let transport = AgentPaneTransport()
        transport.deliver = { _, done in done() }
        transport.personRecoveryDelays = [.milliseconds(1)]
        let record = Record()
        transport.onPersonProofFailed = { record.told.append($0) }
        transport.recoverPersonProof = { record.lookups += 1; return true }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil,
                                                           socketPath: Self.keyedSocketPath()))
        // What `open` sets when the accepted end is another cmux install's acpmux (AcpmuxServerPeer
        // .foreign); the stand-in has no executable for that check to read.
        transport.daemonIsForeign = true
        #expect(await transport.send(connection: id, frames: [Self.initialize]) == nil)
        #expect(await Self.until { !record.told.isEmpty })
        #expect(record.told == [false], "another install's daemon raised the identity notice: \(record.told)")
        #expect(Self.proofs(server) == 0, "a person proof went to another install's daemon")
        #expect(record.lookups == 0)
        #expect(transport.connection == id, "the pane reconnected to another install's daemon")
    }
}
