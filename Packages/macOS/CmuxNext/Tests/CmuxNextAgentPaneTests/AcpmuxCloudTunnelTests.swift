import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Cloud tunnel palette commands (`cloudTunnelAttach`, `cloudTunnelDetach`,
/// `cloudTunnelRotateKey`) call this app's acpmux, never classic Cloud: each is one
/// `_acpmux/machine.tunnel.*` call on a person-proved line, with the person's token, and a line
/// whose proof acpmux did not take never sees the token.
@MainActor
struct AcpmuxCloudTunnelTests {
    @MainActor final class Line: AgentDialogLine {
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
        try await Self.tunnel(line).run(.rekey, token: "person-token", networkID: "team_1")
        #expect(line.calls.map(\.method) == [
            "_acpmux/machine.tunnel.attach", "_acpmux/machine.tunnel.detach", "_acpmux/machine.tunnel.rekey",
        ])
        #expect(line.calls.allSatisfy { $0.params["token"] as? String == "person-token" })
        #expect(line.calls[0].params["networkId"] as? String == "team_1")
        #expect(line.calls[1].params["networkId"] as? String == "team_1")
        // A rekey takes no key and no network: the daemon makes the key.
        #expect(Set(line.calls[2].params.keys) == ["token"])
        #expect(line.closed)
    }

    @Test func aLineWithoutThePersonProofNeverSeesTheToken() async {
        let line = Line(isPerson: false)
        await #expect(throws: AcpmuxCloudTunnel.Refusal.self) {
            _ = try await Self.tunnel(line).run(.rekey, token: "person-token")
        }
        #expect(line.calls.isEmpty)
        #expect(line.closed)
        await #expect(throws: AcpmuxCloudTunnel.Refusal.self) {
            _ = try await Self.tunnel(nil).run(.attach, token: "person-token")
        }
    }

    /// No network id (the palette's and CLI's default) sends none: acpmux takes the joined team's.
    @Test func noNetworkIDSendsNone() async throws {
        let line = Line(isPerson: true)
        try await Self.tunnel(line).run(.attach, token: "person-token")
        try await Self.tunnel(line).run(.detach, token: "person-token", networkID: nil)
        #expect(line.calls.map { $0.params["networkId"] == nil } == [true, true])
        #expect(line.calls.map { $0.params["token"] as? String } == ["person-token", "person-token"])
    }

    @Test func aRefusalSaysTheDaemonsOwnWords() async {
        let line = Line(isPerson: true, reply: nil, lastError: "a rekey of this Mac's WireGuard key is already running")
        do {
            _ = try await Self.tunnel(line).run(.rekey, token: "person-token")
            Issue.record("a refused rekey returned")
        } catch {
            #expect(error.localizedDescription == "a rekey of this Mac's WireGuard key is already running")
        }
        let silent = Line(isPerson: true, reply: nil)
        do {
            _ = try await Self.tunnel(silent).run(.detach, token: "person-token")
            Issue.record("a refused detach returned")
        } catch {
            #expect(error.localizedDescription == "no daemon")
        }
    }

    /// Over a real person line to a fake acpmux whose platform call takes 6 s, past a person
    /// line's usual 5 s: the call still answers, since its line lives the whole operation.
    @Test func aSlowTunnelCallStillAnswersOverTheRealLine() async throws {
        let socket = "/tmp/act-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let daemon = try HiddenHomeApprovalTests.FakeAcpmux(socket: socket, key: AcpmuxPersonKey.spawnKey(for: socket))
        defer { daemon.stop() }
        daemon.tunnelDelay = 6
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath(),
            home: URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent), socketPath: socket,
            daemonArguments: [], childEnvironment: [:])
        let reply = try await AcpmuxCloudTunnel(environment, fallback: "no daemon").run(.rekey, token: "person-token")
        #expect(reply["machineId"] as? String == "machine_1")
        #expect(daemon.methods == ["initialize", "_acpmux/person_prove", "_acpmux/machine.tunnel.rekey"])
        #expect(AcpmuxCloudTunnel.deadline >= .seconds(60))
    }
}
