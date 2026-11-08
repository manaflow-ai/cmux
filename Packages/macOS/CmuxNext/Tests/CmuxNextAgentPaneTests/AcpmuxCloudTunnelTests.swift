import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Cloud tunnel palette commands (`cloudTunnelAttach`, `cloudTunnelDetach`) call this app's
/// acpmux, never classic Cloud: each is one
/// `_acpmux/machine.tunnel.*` call on a person-proved line, with the person's token, and a line
/// whose proof acpmux did not take never sees the token.
@MainActor
struct AcpmuxCloudTunnelTests {
    final class Line: AgentDialogLine {
        let isPerson: Bool
        var reply: [String: Any]?
        var lastError: String?
        var calls: [(method: String, params: [String: Any])] = []
        var closed = false

        init(isPerson: Bool, reply: [String: Any]? = ["ok": true], lastError: String? = nil) {
            self.isPerson = isPerson
            self.reply = reply
            self.lastError = lastError
        }

        func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
            calls.append((method, params))
            return reply
        }

        func close() { closed = true }
    }

    static func tunnel(_ line: Line?) -> AcpmuxCloudTunnel {
        AcpmuxCloudTunnel(open: { line }, fallback: "no daemon")
    }

    @Test func eachCommandIsOneDaemonCallWithThePersonsToken() async throws {
        let line = Line(isPerson: true)
        try await Self.tunnel(line).run(.attach, token: "person-token", networkID: "team_1")
        try await Self.tunnel(line).run(.detach, token: "person-token", networkID: "team_1")
        #expect(line.calls.map(\.method) == ["_acpmux/machine.tunnel.attach", "_acpmux/machine.tunnel.detach"])
        #expect(line.calls.allSatisfy { $0.params["token"] as? String == "person-token" })
        #expect(line.calls[0].params["networkId"] as? String == "team_1")
        #expect(line.calls[1].params["networkId"] as? String == "team_1")
        #expect(line.closed)
    }

    @Test func aLineWithoutThePersonProofNeverSeesTheToken() async {
        let line = Line(isPerson: false)
        await #expect(throws: AcpmuxCloudTunnel.Refusal.self) {
            try await Self.tunnel(line).run(.attach, token: "person-token")
        }
        #expect(line.calls.isEmpty)
        #expect(line.closed)
        await #expect(throws: AcpmuxCloudTunnel.Refusal.self) {
            try await Self.tunnel(nil).run(.attach, token: "person-token")
        }
    }

    @Test func aRefusalSaysTheDaemonsOwnWords() async {
        let line = Line(isPerson: true, reply: nil, lastError: "this Mac is not joined to a cmux team; add it first")
        do {
            try await Self.tunnel(line).run(.attach, token: "person-token")
            Issue.record("a refused attach returned")
        } catch {
            #expect(error.localizedDescription == "this Mac is not joined to a cmux team; add it first")
        }
        let silent = Line(isPerson: true, reply: nil)
        do {
            try await Self.tunnel(silent).run(.detach, token: "person-token")
            Issue.record("a refused detach returned")
        } catch {
            #expect(error.localizedDescription == "no daemon")
        }
    }
}
