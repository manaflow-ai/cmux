#if DEBUG
public import Foundation

/// The live-action seam for the DEBUG split / child-exit UI-test scaffolds.
///
/// ``UITestSplitScaffoldGate`` decides *which* scaffolds run and parses their
/// configuration (pure value logic, owned by this package). The actual
/// scaffolds drive AppKit windows, Bonsplit pane trees, Ghostty terminal
/// surfaces, the keyboard-shortcut store, and a `CVDisplayLink` IOSurface
/// timeline. That live state lives in the app target and cannot cross the
/// package boundary, so the app conforms this protocol and the package calls
/// back into it for each enabled scaffold.
///
/// The seam is intentionally `#if DEBUG` only: these harnesses exist purely for
/// XCUITest instrumentation and are compiled out of release builds, matching
/// the legacy `#if DEBUG` block they were extracted from.
///
/// Isolation: `@MainActor`, because every scaffold reads and mutates main-actor
/// terminal/window state. Each method is fire-and-forget setup; a scaffold that
/// needs to await surface readiness owns its own `Task` internally, exactly as
/// the legacy bodies did.
@MainActor
public protocol UITestScaffoldRunning: AnyObject {
    /// Installs the letter-based pane-focus shortcuts used by navigation tests.
    func installUITestFocusShortcuts()

    /// Runs the split-then-close-right harness with the parsed configuration.
    func runSplitCloseRightUITest(_ config: UITestSplitScaffoldPlan.SplitCloseRightConfig)

    /// Runs the child-exit split harness with the parsed configuration.
    func runChildExitSplitUITest(_ config: UITestSplitScaffoldPlan.ChildExitSplitConfig)

    /// Runs the child-exit keyboard harness with the parsed configuration.
    func runChildExitKeyboardUITest(_ config: UITestSplitScaffoldPlan.ChildExitKeyboardConfig)
}

extension UITestScaffoldRunning {
    /// Drives every scaffold the `plan` enables, in the legacy setup order
    /// (focus shortcuts, then split-close-right, then child-exit split, then
    /// child-exit keyboard).
    ///
    /// The owner builds the plan once with ``UITestSplitScaffoldGate`` and calls
    /// this from its init so the dispatch decision is not re-expressed at the
    /// call site.
    ///
    /// - Parameter plan: The parsed scaffold plan for this process.
    public func runEnabledScaffolds(for plan: UITestSplitScaffoldPlan) {
        if plan.installsFocusShortcuts {
            installUITestFocusShortcuts()
        }
        if let splitCloseRight = plan.splitCloseRight {
            runSplitCloseRightUITest(splitCloseRight)
        }
        if let childExitSplit = plan.childExitSplit {
            runChildExitSplitUITest(childExitSplit)
        }
        if let childExitKeyboard = plan.childExitKeyboard {
            runChildExitKeyboardUITest(childExitKeyboard)
        }
    }
}
#endif
