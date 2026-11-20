import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The waiting line's word on the daemon a handshake waits on (`acpmux.serviceWait`). Leo,
/// 2026-11-18: "i cant connect to agent service? something? :(" over "Waiting for the agent service
/// (1:10)  Restart agent service", while the daemon was alive and slow. The host probes the pid
/// file's process and the socket; Rust decides busy, starting or down (cmux-agent-pane-policy
/// service_wait.rs, whose own tests hold the rules).
@Suite(.serialized)
@MainActor
struct AcpmuxServiceWaitTests {
    private actor WaitHost: AgentPaneHostProviding {
        private(set) var asked: [Int] = []
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func agentServiceWait(sessionId: String?, waitedMs: Int) async -> AgentServiceWait? {
            asked.append(waitedMs)
            return AgentServiceWait(state: "busy", restart: false)
        }
    }

    /// The page asks with how long it waited; the host's word goes back as `{state, restart}`, no gesture needed.
    @Test func thePageGetsTheHostsWord() async {
        let host = WaitHost()
        let model = AgentPaneModel(host: host)
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.serviceWait", "params": ["waitedMs": 70_000]]))
        let value = reply["value"] as? [String: Any]
        #expect(value?["state"] as? String == "busy", "\(reply)")
        #expect(value?["restart"] as? Bool == false, "\(reply)")
        #expect(await host.asked == [70_000])
    }

    /// A request without a whole, non-negative wait is refused before the host.
    @Test func aMalformedWaitIsRefused() {
        for params: [String: Any] in [[:], ["waitedMs": -1], ["waitedMs": "70000"], ["waitedMs": 1e12]] {
            let request = AgentPaneRequest(body: ["method": "acpmux.serviceWait", "params": params])
            guard case .unsupported = request else {
                Issue.record("\(params) decoded as \(request)")
                continue
            }
        }
    }

    /// A host without a daemon of its own cannot tell: `{}`, and the page draws its plain line.
    @Test func aHostWithoutADaemonSaysNothing() async {
        struct Plain: AgentPaneHostProviding {
            func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        }
        let model = AgentPaneModel(host: Plain())
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.serviceWait", "params": ["waitedMs": 30_000]]))
        #expect((reply["value"] as? [String: Any])?.isEmpty == true, "\(reply)")
    }

    /// No pid file and nothing on the socket is down; a listener on the socket takes the probe's
    /// connect even though it never reads it (a daemon whose workers are all busy).
    @Test func theProbeSeesAListenerAndNoProcess() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socketPath = home.appendingPathComponent("s.sock").path
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/true"), home: home, socketPath: socketPath,
                                             daemonArguments: [], childEnvironment: [:])
        #expect(await AcpmuxServiceWait.probe(environment) == .init(processAlive: false, socketAccepts: false))

        let listener = try Self.listen(socketPath)
        defer { Darwin.close(listener) }
        #expect(await AcpmuxServiceWait.probe(environment) == .init(processAlive: false, socketAccepts: true))
    }

    /// Rust's verdict through the app FFI: nil on an FFI pinned before `service_wait`, else the rules.
    @Test func theVerdictIsRusts() {
        guard let busy = AcpmuxServiceWait.verdict(.init(processAlive: true, socketAccepts: true), waitedMs: 70_000) else { return }
        #expect(busy == AgentServiceWait(state: "busy", restart: false))
        #expect(AcpmuxServiceWait.verdict(.init(processAlive: false, socketAccepts: false), waitedMs: 0)
            == AgentServiceWait(state: "down", restart: true))
        #expect(AcpmuxServiceWait.verdict(.init(processAlive: true, socketAccepts: false), waitedMs: 30_000)
            == AgentServiceWait(state: "starting", restart: false))
    }

    /// A unix socket listening at `path` that never accepts.
    private static func listen(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && Darwin.listen(descriptor, 4) == 0)
        return descriptor
    }
}

extension AcpmuxServiceWaitTests {
    /// The line asks by itself every few seconds: no touch, so the page stays a spare one.
    @Test func askingIsNotATouch() async {
        let model = AgentPaneModel(host: WaitHost())
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "acpmux.serviceWait", "params": ["waitedMs": 30_000]]))
        #expect(!model.userTouched)
    }
}
