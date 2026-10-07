import Testing
@testable import CmuxNextDaemon

/// A cmux-next terminal sets `CMUX_SOCKET_PATH` to cmux-next's socket, so the
/// `cmux` its shell runs must be cmux-next's own CLI. Appending the bundle's
/// bin dir let an earlier `cmux` (the old app's, a dev shim) win and send old
/// method names to cmux-next ("Unknown method workspace.create").
@Suite struct BundledCLIPathTests {
    let resources = "/App/Contents/Resources/ghostty"
    let binary = "/App/Contents/Resources/bin/ghostty"
    let oldApp = "/Applications/cmux.app/Contents/Resources/bin"
    func dirs(_ path: String) -> Bool { false }

    @Test func bundledCLIBinDirGoesFirst() {
        let integration = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: binary)
        let env = integration.apply(
            to: ["PATH": "\(oldApp):/usr/bin:/App/Contents/Resources/bin", "CMUX_BUNDLED_CLI_PATH": "\(oldApp)/cmux"],
            isDirectory: dirs, isExecutable: { $0 == "/App/Contents/Resources/bin/cmux" })
        #expect(env["PATH"] == "/App/Contents/Resources/bin:\(oldApp):/usr/bin")
        #expect(env["CMUX_BUNDLED_CLI_PATH"] == "/App/Contents/Resources/bin/cmux")
    }

    @Test func withoutABundledCLIThePathIsAppendedAsGhosttyDoes() {
        let integration = GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: binary)
        let env = integration.apply(to: ["PATH": "/usr/bin"], isDirectory: dirs, isExecutable: { _ in false })
        #expect(env["PATH"] == "/usr/bin:/App/Contents/Resources/bin")
        #expect(env["CMUX_BUNDLED_CLI_PATH"] == nil)
    }
}
