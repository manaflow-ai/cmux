import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

@Suite("Tunnel port policy and detection")
struct TunnelPolicyTests {
    let principal = MobileDevicePrincipal(install: "in_phone1", userID: "u_alice", platform: "ios", appVersion: "1.0")

    @Test func privilegedDeniedAndUnadvertisedPortsAreRefused() {
        let policy = MobileTunnelPolicy(configuration: MobileTunnelConfiguration(deniedPorts: [7777]))
        let advertised = [TunnelPort(port: 22, source: .allowed), TunnelPort(port: 7777, source: .detected),
                          TunnelPort(port: 5173, source: .detected, workspace: "ws_a1")]
        #expect(policy.check(22, advertised: advertised) == .failure(.privileged))
        #expect(policy.check(7777, advertised: advertised) == .failure(.denied))
        #expect(policy.check(3000, advertised: advertised) == .failure(.notAdvertised))
        #expect(policy.check(5173, advertised: advertised) == .success(advertised[2]))
        #expect(policy.admitted(advertised).map(\.port) == [5173])
    }

    @Test func detectionMergesWorkspaceListenersAndTheAllowlist() async {
        let directory = DetectedTunnelPorts(
            processes: FixedProcesses([MobileWorkspaceProcess(pid: 10, workspace: "ws_a1", name: "node"),
                                       MobileWorkspaceProcess(pid: 11, workspace: "ws_b2", name: "python")]),
            scanner: FixedScanner([10: [5173, 24678], 11: [8000], 99: [9999]]),
            allowed: StaticAllowedPorts([8000, 8080]))
        let ports = await directory.ports(for: principal)
        #expect(ports == [TunnelPort(port: 5173, source: .detected, workspace: "ws_a1", process: "node"),
                          TunnelPort(port: 8000, source: .detected, workspace: "ws_b2", process: "python"),
                          TunnelPort(port: 8080, source: .allowed),
                          TunnelPort(port: 24678, source: .detected, workspace: "ws_a1", process: "node")])
    }

    @Test func libprocFindsAListenerOfThisProcess() async throws {
        let server = try await EchoServer.start()
        defer { server.stop() }
        let ports = LibprocListeningPortScanner().listeningPorts(of: [getpid()])
        #expect(ports[getpid()]?.contains(server.port) == true)
        #expect(LibprocListeningPortScanner().listeningPorts(of: [-1]).isEmpty)
    }
}

struct FixedProcesses: MobileWorkspaceProcesses {
    let list: [MobileWorkspaceProcess]
    init(_ list: [MobileWorkspaceProcess]) { self.list = list }
    func processes() async -> [MobileWorkspaceProcess] { list }
}

struct FixedScanner: ListeningPortScanner {
    let table: [Int32: [UInt16]]
    init(_ table: [Int32: [UInt16]]) { self.table = table }
    func listeningPorts(of pids: [Int32]) -> [Int32: [UInt16]] { table.filter { pids.contains($0.key) } }
}
