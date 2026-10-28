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
        let env = TerminalEnvironment.instance.ghostty(
            resourcesDirectory: resources, version: nil, fileExists: { $0 == "/usr/share/terminfo/78/xterm-ghostty" })
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TERMINFO"] == nil)
    }
}
