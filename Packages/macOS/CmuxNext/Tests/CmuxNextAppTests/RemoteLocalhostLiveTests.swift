import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import Foundation
import Testing
@testable import CmuxNextApp

/// Live check against a real cmux-tui daemon (a second local session or a
/// remote socket), skipped unless `CMUX_RL_LIVE_SOCKET` names its socket.
/// `CMUX_RL_LIVE_CHECK` is a node script that drives the proxy
/// (plans/cmux-next/remote-localhost.md, verification).
struct RemoteLocalhostLiveTests {
    nonisolated static let socket = ProcessInfo.processInfo.environment["CMUX_RL_LIVE_SOCKET"]
    nonisolated static let script = ProcessInfo.processInfo.environment["CMUX_RL_LIVE_CHECK"]

    @Test(.enabled(if: socket != nil && script != nil), .timeLimit(.minutes(2)))
    func proxyReachesTheDaemonMachinesLoopback() async throws {
        let socket = try #require(Self.socket), script = try #require(Self.script)
        let env = ProcessInfo.processInfo.environment
        let client = LoopbackForwardClient { DaemonEndpoint(socketPath: socket) }
        let proxy = RemoteLocalhostProxy()
        let port = try await proxy.start()
        defer { proxy.stop() }
        let machine = env["CMUX_RL_LIVE_MACHINE"] ?? "live-machine"
        let credential = proxy.credential(for: "live", route: .init(machineName: machine, opener: DaemonLoopbackOpener(client: client)))
        let process = Process()
        process.executableURL = URL(filePath: env["CMUX_RL_NODE"] ?? "/usr/bin/env")
        process.arguments = env["CMUX_RL_NODE"] == nil ? ["node", script] : [script]
        var childEnv = env
        childEnv["PROXY_PORT"] = String(port)
        childEnv["PROXY_AUTH"] = "\(credential.username):\(credential.password)"
        childEnv["MACHINE"] = machine
        process.environment = childEnv
        let finished = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished.continuation.yield($0.terminationStatus) }
        try process.run()
        var status: Int32 = -1
        for await code in finished.stream {
            status = code
            break
        }
        let stats = proxy.stats
        print("remote-localhost live: exit \(status), stats \(stats), open streams \(await client.openStreamCount)")
        #expect(status == 0)
        #expect(stats.tunnels > 0)
        await client.close()
    }
}
