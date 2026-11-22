import AppKit
import Foundation
import Testing

/// What the test host offers. The headless lane (a fleet step on a Mac with
/// no display, such as the EC2 Macs) has no window server display and no
/// pasteboard server reachable from the step, so tests that need them are
/// reported SKIPPED there instead of failing. The GUI lane sets
/// `CMUX_TEST_REQUIRE_GUI=1`: then nothing is skipped, and a missing display
/// or pasteboard fails the test as it should.
///
/// The same file is in Tests/CmuxNextAppTests (test targets cannot share a file
/// without a manifest change); keep the two copies equal.
enum TestHostSession {
    nonisolated static var isRequired: Bool { ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" }

    /// True when the window server reports at least one screen.
    @MainActor static var hasDisplay: Bool { !NSScreen.screens.isEmpty }

    /// True when a private named pasteboard keeps a string.
    @MainActor static var hasPasteboard: Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux-test-probe-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        guard pasteboard.setString("probe", forType: .string) else { return false }
        return pasteboard.string(forType: .string) == "probe"
    }
}

extension Trait where Self == ConditionTrait {
    /// The test needs a GUI session with a display; the headless lane skips it.
    static var requiresGUISession: Self {
        .enabled("needs a GUI session with a display (skipped in the headless lane)") {
            TestHostSession.isRequired ? true : await TestHostSession.hasDisplay
        }
    }

    /// The test needs a working pasteboard; the headless lane skips it.
    static var requiresPasteboard: Self {
        .enabled("needs a pasteboard server (skipped in the headless lane)") {
            TestHostSession.isRequired ? true : await TestHostSession.hasPasteboard
        }
    }
}
