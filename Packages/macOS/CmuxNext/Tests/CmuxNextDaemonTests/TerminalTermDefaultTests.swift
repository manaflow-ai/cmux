import Foundation
import Testing
@testable import CmuxNextCompat
@testable import CmuxNextDaemon

/// Terminals must advertise a TERM that every host (ssh targets, VMs,
/// containers) understands, unless the ghostty terminfo is installed here.
/// That check reads the disk, so it runs once per launch on the app's files
/// lane (`GhosttyLaunchProbe`); the identity the app builds on the main thread
/// reads nothing.
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
}
