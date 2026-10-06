@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// The app starts acpmux with no dev origin and no `--dev`, in Debug and in Release, even when it
/// shows the dev server page: the host's socket (AgentPaneTransport) always carries the bundled
/// pane's origin, so LocalApp needs neither, and a release acpmux never runs with its dev unlock.
@MainActor
@Suite struct AgentPaneDaemonArgumentsTests {
    private func fakeExecutable() throws -> URL {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return bin
    }

    @Test func aDevServerPageStartsTheDaemonWithoutDevFlags() throws {
        let bin = try fakeExecutable()
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:4176/", "PATH": ""]
        for tag in [nil, "dev-tag"] as [String?] {
            let resolved = try #require(AgentTabStore.paneEnvironment(tag: tag, bundledBinDirectory: bin, environment: environment))
            let arguments = AcpmuxDaemonLauncher.arguments(for: resolved)
            #expect(!arguments.contains("--allow-dev-origin"), "\(arguments)")
            #expect(!arguments.contains("--dev"), "\(arguments)")
        }
    }
}
