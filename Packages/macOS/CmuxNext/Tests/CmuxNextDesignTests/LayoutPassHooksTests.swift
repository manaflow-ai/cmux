import AppKit
@testable import CmuxNextDesign
import Testing

/// `LayoutPassGuard` counts layouts through `LayoutPassHooks`, the seam that replaces
/// `-[NSView layout]` and `-[NSWindow layoutIfNeeded]`: a view laid out on main, inside its
/// window's layout and outside it, reaches the guard's per-class counts, and the window bracket
/// is open exactly while `layoutIfNeeded` runs.
///
/// The test installs `LayoutPassGuard.shared`, not a guard of its own: the replacements are
/// process-wide method implementations (one per process, as the app installs at launch), and a
/// second guard would stack a second replacement over the first for every later suite. With the
/// shared install, every suite in the process lays out through exactly one replacement, as the
/// app does. Installing replaces both methods for the rest of the test process.
///
/// This is a behavior-preservation check for the move into the seam, not a red/green guard: it
/// passes on the code before the move too (the merge of the window bracket's two main-actor
/// entries into one changes no count). Not covered here: the main run loop's before-waiting
/// observer that drops a leaked bracket (it fires only when the main run loop is about to sleep).
@MainActor
@Suite struct LayoutPassHooksTests {
    /// Its own class, so other suites' layouts never add to its count. It notes whether its
    /// window's layout bracket was open during its last layout.
    private final class CountedView: NSView {
        var guardian: LayoutPassGuard?
        var layoutInsideWindowLayout: Bool?

        override func layout() {
            super.layout()
            if let guardian, let window { layoutInsideWindowLayout = guardian.isInWindowLayout(window) }
        }
    }

    @Test func aViewLaidOutOnMainReachesTheGuardThroughTheHooks() {
        let guardian = LayoutPassGuard.shared
        guardian.install()
        #expect(guardian.isInstalled)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = CountedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.guardian = guardian
        window.contentView = view

        view.needsLayout = true
        window.layoutIfNeeded()
        #expect(view.layoutInsideWindowLayout == true, "the replaced -[NSWindow layoutIfNeeded] did not open its bracket")
        #expect(!guardian.isInWindowLayout(window), "the bracket stayed open after -[NSWindow layoutIfNeeded] returned")

        view.layoutInsideWindowLayout = nil
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.layoutInsideWindowLayout == false, "a layout outside the window's layout counted inside it")

        let name = String(describing: CountedView.self)
        #expect(guardian.passesByClass.contains { $0.viewClass == name && $0.passes > 0 },
                "the replaced -[NSView layout] did not reach the guard")
    }
}
