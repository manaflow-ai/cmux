import Foundation
import Testing
@testable import CmuxNextDaemon

/// A terminal the daemon starts without a caller env (`cmux tab create
/// terminal`, `cmux workspace create` from a shell) gets the daemon's own
/// environment. Its `cmux` must still be this app's bundled CLI, so the
/// daemon starts with the bundled bin dir first on `PATH` and with
/// `CMUX_BUNDLED_CLI_PATH`; the daemon's shell integration keeps it first after
/// the user's startup files (cmux-tui `shell_integration::cli_path`).
@Suite struct DaemonBundledCLIEnvironmentTests {
    @Test func theDaemonEnvironmentPutsTheBundledCLIFirst() async throws {
        let app = try FakeAppBundle()
        defer { app.remove() }
        let launcher = try DaemonLauncher.forApp(
            tag: nil, terminalEnvironment: ["CMUX_TAG": "t"], bundle: app.bundle,
            processEnvironment: ["PATH": "/Users/u/.local/bin:/usr/bin:/bin", "HOME": "/Users/u",
                                 "CMUX_BUNDLED_CLI_PATH": "/Applications/cmux.app/Contents/Resources/bin/cmux"])
        let environment = await launcher.ensureEnvironment()
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == app.binDirectory)
        #expect(path.filter { $0 == app.binDirectory }.count == 1)
        #expect(environment["CMUX_BUNDLED_CLI_PATH"] == app.binDirectory + "/cmux")
        #expect(environment["CMUX_TAG"] == "t")
    }
}

/// `<tmp>/cmux DEV t.app` with an executable `cmux-tui` and `cmux` in
/// `Contents/Resources/bin`.
private struct FakeAppBundle {
    let root: URL
    let bundle: Bundle
    let binDirectory: String

    init() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("cmux-daemon-cli-\(UUID().uuidString)")
        root = base.appendingPathComponent("cmux DEV t.app")
        let contents = root.appendingPathComponent("Contents")
        let bin = contents.appendingPathComponent("Resources/bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.cmuxterm.app.debug.cli-env-test",
                                    "CFBundlePackageType": "APPL", "CFBundleName": "cmux DEV t"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for name in ["cmux-tui", "cmux"] {
            let file = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        guard let bundle = Bundle(url: root) else { throw CocoaError(.fileReadCorruptFile) }
        self.bundle = bundle
        binDirectory = (bundle.resourceURL?.path ?? bin.path) + "/bin"
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
