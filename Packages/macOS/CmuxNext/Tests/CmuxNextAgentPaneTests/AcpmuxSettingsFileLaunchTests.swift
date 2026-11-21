import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agents acpmux starts read the settings file the app runs on: the app's launch environment
/// (`LaunchIdentity.terminalEnvironment`, which names it as ``SettingsFileOverride`` resolves it)
/// reaches the acpmux daemon's spawn environment, even for a signed daemon that inherits only a
/// short list of the app's variables; acpmux passes its own environment to each local agent.
struct AcpmuxSettingsFileLaunchTests {
    @Test func theAppsSettingsFileReachesTheAcpmuxDaemonItsAgentsRunUnder() throws {
        let root = URL(fileURLWithPath: "/tmp/asf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let file = SettingsFileOverride(environment: [SettingsFileOverride.key: "~/.config/cmux/cmux-next-cu-fresh.json"],
                                        home: URL(fileURLWithPath: "/Users/someone")).path
        let expected = "/Users/someone/.config/cmux/cmux-next-cu-fresh.json"
        #expect(file == expected)
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin,
            environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
            launchEnvironment: [SettingsFileOverride.key: expected],
            executableOverride: nil
        ))
        // A signed daemon (no person key at spawn) inherits nothing of the app's own environment.
        var signed = environment
        signed.passesPersonKeyAtSpawn = false
        for launched in [environment, signed] {
            let variables = AcpmuxDaemonLauncher.spawnEnvironment(launched, inherited: ["CMUX_NEXT_CONFIG_FILE": "/elsewhere.json"])
            #expect(variables[SettingsFileOverride.key] == expected)
        }
    }
}
