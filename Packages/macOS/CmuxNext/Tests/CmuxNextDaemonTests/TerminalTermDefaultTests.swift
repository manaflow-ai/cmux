import Foundation
import Testing
@testable import CmuxNextCompat
@testable import CmuxNextDaemon

/// Terminals advertise the `TERM` every host (ssh targets, VMs, containers) understands
/// (Lawrence 2026-10-28: "default echo $TERM should not use the ghostty one but should use the
/// standard one that every tool recognizes, for all cmux"). The identity the app builds on the
/// main thread reads nothing (p02-threads-006).
struct TerminalTermDefaultTests {
    private let resources = "/Applications/cmux.app/Contents/Resources/ghostty"

    @Test func theIdentityIsTheStandardTermWithGhosttysFeatureKeys() {
        let env = TerminalEnvironment.instance.ghostty(resourcesDirectory: resources, version: "1.2.3")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["TERMINFO"] == nil)
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(env["TERM_PROGRAM_VERSION"] == "1.2.3")
        #expect(env["GHOSTTY_RESOURCES_DIR"] == resources)
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
