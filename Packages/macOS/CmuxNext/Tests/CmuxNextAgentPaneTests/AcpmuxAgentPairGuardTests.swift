import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The `agent.pairGuard` Debug Settings toggle at the daemon spawn boundary: on (the default) the
/// acpmux daemon keeps its agent message runaway guard and gets no `ACPMUX_AGENT_PAIR_GUARD`;
/// off, it gets `ACPMUX_AGENT_PAIR_GUARD=0` (acpmux `hub/agent_pairs.rs`).
struct AcpmuxAgentPairGuardTests {
    static func environment() throws -> (AcpmuxEnvironment, URL) {
        let root = URL(fileURLWithPath: "/tmp/apg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin,
            environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
            executableOverride: nil
        ))
        return (environment, root)
    }

    @Test func theGuardStaysOnUnlessTheToggleIsOff() throws {
        var (environment, root) = try Self.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(environment.agentPairGuard)
        let on = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: [:])
        #expect(on[AcpmuxEnvironment.agentPairGuardKey] == nil)
        #expect(on[AcpmuxEnvironment.agentPairCapKey] == "20")
        #expect(on[AcpmuxEnvironment.agentPairWindowKey] == "600")
        environment.agentPairCap = 0
        let uncapped = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: [:])
        #expect(uncapped[AcpmuxEnvironment.agentPairCapKey] == "0")
        environment.agentPairGuard = false
        let off = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: [:])
        #expect(off[AcpmuxEnvironment.agentPairGuardKey] == "0")
        #expect(off[AcpmuxEnvironment.agentPairCapKey] == nil)
    }
}
