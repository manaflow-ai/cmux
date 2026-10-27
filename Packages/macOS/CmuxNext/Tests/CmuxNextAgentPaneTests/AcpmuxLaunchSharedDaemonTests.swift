import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The real daemon keeps its identity and another Chief's live chat when this app ends its tab.
@Suite(.timeLimit(.minutes(2)))
struct AcpmuxLaunchSharedDaemonTests {
    @Test func launchAndQuitNeverReplaceOrShutdownASharedDaemon() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url, "fleet lane must supply the same-tree acpmux")
        let root = URL(fileURLWithPath: "/tmp/alw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        let fake = repo.appendingPathComponent("cmux-tui/crates/acpmux/tests/fake_agent.py")
        try #require(FileManager.default.fileExists(atPath: fake.path))
        let config: [String: Any] = ["harnesses": ["fake": ["argv": ["/usr/bin/python3", fake.path]]],
                                     "defaultHarness": "fake", "store": ["mode": "memory"]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        let socket = root.appendingPathComponent("d.sock").path
        func environment(_ executable: URL) -> AcpmuxEnvironment {
            AcpmuxEnvironment(executable: executable, home: root, socketPath: socket, daemonArguments: [],
                              childEnvironment: ["ACPMUX_HOME": root.path, "ACPMUX_SOCKET": socket])
        }
        let owner = environment(binary)
        try await AcpmuxLaunchConnection(environment: owner, mayStart: true).prepare()
        do {
            let before = try await AcpmuxStatusClient.status(socketPath: socket)
            let params: [String: any Sendable] = ["cwd": root.path, "mcpServers": [String]()]
            let mine = try await AcpmuxStatusClient.call(socketPath: socket, method: "session/new", params: params, deadline: .seconds(15))
            let other = try await AcpmuxStatusClient.call(socketPath: socket, method: "session/new", params: params, deadline: .seconds(15))
            let mineID = try #require(mine["sessionId"] as? String)
            let otherID = try #require(other["sessionId"] as? String)
            // A different build's binary cannot start or replace anything: automatic warm must
            // use the existing daemon without trying its normal handoff/enrollment path.
            let tabs = AcpmuxHost(environment: environment(URL(fileURLWithPath: "/usr/bin/false")))
            try await tabs.warm(sessionIds: [mineID])
            #expect(await tabs.endLaunchSessions(waitForShutdown: false) == .ended)
            let after = try await AcpmuxStatusClient.status(socketPath: socket)
            #expect(after.pid == before.pid)
            let listing = try await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(5)).value
            let rows = try #require(listing["sessions"] as? [[String: Any]])
            #expect(rows.first { $0["sessionId"] as? String == mineID }?["status"] as? String == "idle")
            #expect(rows.first { $0["sessionId"] as? String == otherID }?["status"] as? String == "ready")
        } catch {
            _ = await AcpmuxQuit.endAgents(owner, keep: .nothing)
            throw error
        }
        #expect(await AcpmuxQuit.endAgents(owner, keep: .nothing) == .ended)
    }
}
