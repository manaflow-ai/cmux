import CmuxNextRemoteBrowser
import Foundation
import Testing

/// The remote browser host runs as a second executable of the app
/// (`Contents/MacOS/cmux-remote-browser-host`), so its sandboxed helpers can
/// read the app's CEF framework (scripts/cmux-next/remote-browser-host-layout.sh).
/// The locator finds that executable, and never the earlier
/// `Contents/Helpers/cmux-remote-browser-host.app`, whose helpers ran with the
/// sandbox off.
struct LocalRemoteBrowserHostLocatorTests {
    @Test func theEmbeddedHostIsTheAppsSecondExecutable() {
        let app = URL(fileURLWithPath: "/Applications/cmux.app")
        let locator = LocalRemoteBrowserHostLocator(environment: [:], appBundle: app)
        #expect(locator.candidates.map(\.path) == ["/Applications/cmux.app/Contents/MacOS/cmux-remote-browser-host"])
    }

    @Test func anOverrideAppNamesItsExecutableFirst() {
        let app = URL(fileURLWithPath: "/Applications/cmux.app")
        let locator = LocalRemoteBrowserHostLocator(
            environment: [LocalRemoteBrowserHostLocator.environmentKey: "/tmp/host/cmux-remote-browser-host.app"],
            appBundle: app
        )
        #expect(locator.candidates.map(\.path) == [
            "/tmp/host/cmux-remote-browser-host.app/Contents/MacOS/cmux-remote-browser-host",
            "/Applications/cmux.app/Contents/MacOS/cmux-remote-browser-host",
        ])
    }

    @Test func theEarlierHelpersLayoutIsNotUsed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rbh-locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "cmux.app")
        let old = app.appending(path: "Contents/Helpers/cmux-remote-browser-host.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let oldExecutable = old.appending(path: "cmux-remote-browser-host")
        #expect(FileManager.default.createFile(atPath: oldExecutable.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        let locator = LocalRemoteBrowserHostLocator(environment: [:], appBundle: app)
        #expect(locator.executable() == nil)

        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let embedded = macOS.appending(path: "cmux-remote-browser-host")
        #expect(FileManager.default.createFile(atPath: embedded.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        #expect(locator.executable()?.path == embedded.path)
    }
}
