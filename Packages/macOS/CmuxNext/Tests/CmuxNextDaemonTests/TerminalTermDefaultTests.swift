import Foundation
import Testing
@testable import CmuxNextCompat
@testable import CmuxNextDaemon

/// Terminals must advertise a TERM that every host (ssh targets, VMs,
/// containers) understands, unless the ghostty terminfo is installed here.
/// That check reads the disk, so it runs once per launch on the app's files
/// lane; the identity the app builds on the main thread reads nothing
/// (p02-threads-006).
struct TerminalTermDefaultTests {
    private let resources = "/Applications/cmux.app/Contents/Resources/ghostty"

    @Test func bundledTerminfoAloneIsNotAnInstalledTerminfo() {
        #expect(!TerminalEnvironment.hasInstalledGhosttyTerminfo(
            home: "/Users/someone", fileExists: { $0.hasSuffix("78/xterm-ghostty") && $0.contains("/Resources/terminfo/") }))
        let env = TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: "1.0")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERMINFO"] == nil)
    }

    @Test func defaultsToXterm256ColorWithNothingInstalled() {
        #expect(!TerminalEnvironment.hasInstalledGhosttyTerminfo(home: "/Users/someone", fileExists: { _ in false }))
        let env = TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERMINFO"] == nil)
        #expect(env["COLORTERM"] == "truecolor")
    }

    @Test func usesGhosttyTermWhenInstalledInSystemTerminfo() {
        #expect(TerminalEnvironment.hasInstalledGhosttyTerminfo(
            home: "/Users/someone", fileExists: { $0 == "/usr/share/terminfo/78/xterm-ghostty" }))
        let env = TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: nil, installedTerminfo: true)
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TERMINFO"] == nil)
    }

    #if DEBUG
    /// `AppEnvironment.current` builds the identity in `main`, on the main thread: it checked 14 terminfo
    /// paths there through `FileManager.checked`.
    @MainActor @Test func theIdentityIsBuiltOnTheMainThreadWithNoFileCheck() async {
        let table = BlockingViolationTable(mode: .record)
        let env = BlockingViolationTable.$scoped.withValue(table) {
            TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: "1.0")
        }
        await table.flush()

        #expect(table.sites.isEmpty, "the identity checked the disk on the main thread: \(table.sites)")
        #expect(env["TERM_PROGRAM"] == "ghostty")
    }
    #endif

    /// The app's launch read reaches every terminal's env, over the overrides' `xterm-256color`.
    @Test(arguments: [true, false])
    func theLaunchReadSetsEachTerminalsTerm(installed: Bool) async {
        let provider = TerminalEnvironment.instance.shared(
            base: [:], overrides: TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: nil),
            installedTerminfo: { installed }, login: { [:] })
        #expect(await provider()["TERM"] == (installed ? "xterm-ghostty" : "xterm-256color"))
    }

    /// The same read reaches the daemon process's own env (terminals it starts with no caller env).
    @Test(arguments: [true, false])
    func theLaunchReadSetsTheDaemonsTerm(installed: Bool) async {
        let cache = LoginEnvironmentCache(store: nil, capture: { _ in nil })
        let environment = DaemonLauncher.appEnvironment(
            cache: cache, base: [:], overrides: TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: nil),
            installedTerminfo: { installed })
        #expect(await environment()["TERM"] == (installed ? "xterm-ghostty" : "xterm-256color"))
    }
}
