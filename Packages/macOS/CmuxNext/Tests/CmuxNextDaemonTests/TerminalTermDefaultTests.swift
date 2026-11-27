import Foundation
import Testing
@testable import CmuxNextDaemon

/// Terminals must advertise a TERM that every host (ssh targets, VMs,
/// containers) understands, unless the ghostty terminfo is installed here.
struct TerminalTermDefaultTests {
    private let resources = "/Applications/cmux.app/Contents/Resources/ghostty"

    @Test func bundledTerminfoAloneDoesNotSelectGhosttyTerm() {
        let env = TerminalEnvironment.instance.ghostty(
            resourcesDirectory: resources, version: "1.0", fileExists: { $0.hasSuffix("78/xterm-ghostty") && $0.contains("/Resources/terminfo/") })
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERMINFO"] == nil)
    }

    @Test func defaultsToXterm256ColorWithNothingInstalled() {
        let env = TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: nil, fileExists: { _ in false })
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERMINFO"] == nil)
        #expect(env["COLORTERM"] == "truecolor")
    }

    @Test func usesGhosttyTermWhenInstalledInSystemTerminfo() {
        // xterm-ghostty is opt-in (terminal.term); installed alone keeps xterm-256color (f0da2e68b213).
        let installed = { (path: String) in path == "/usr/share/terminfo/78/xterm-ghostty" }
        let env = TerminalEnvironment.instance.ghostty(
            resourcesDirectory: resources, version: nil, prefersGhosttyTerm: true, fileExists: installed)
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TERMINFO"] == nil)
        let notOptedIn = TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: nil, fileExists: installed)
        #expect(notOptedIn["TERM"] == "xterm-256color")
    }
}
