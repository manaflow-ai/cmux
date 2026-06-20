public import Foundation

/// The parsed, typed decision of which DEBUG split/child-exit UI-test scaffolds
/// are enabled for this process, and the configuration each one needs.
///
/// The macOS app exposes four `#if DEBUG` XCUITest harnesses that drive split
/// creation, focus changes, and child-exit close flows so an out-of-process
/// XCUITest run can observe internal pane/surface state through capture files.
/// Each harness is gated and configured entirely by process environment
/// variables (`CMUX_UI_TEST_*`). That env parsing is pure value logic with no
/// dependency on any live app object, so it lives here as a tested value type;
/// the live actions each enabled scaffold performs stay in the app target
/// behind ``UITestScaffoldRunning`` because they read and drive AppKit / Ghostty
/// surface state that cannot cross the package boundary.
///
/// Isolation: a pure `Sendable` value tree. ``UITestSplitScaffoldGate`` builds
/// it synchronously from an environment snapshot; it carries no references and
/// performs no I/O.
public struct UITestSplitScaffoldPlan: Sendable, Equatable {
    /// Whether the letter-based focus shortcuts (`Ctrl+Cmd+H/J/K/L`) should be
    /// installed so pane-navigation tests can drive focus without arrow keys.
    ///
    /// Enabled by `CMUX_UI_TEST_FOCUS_SHORTCUTS == "1"`.
    public var installsFocusShortcuts: Bool

    /// Configuration for the split-then-close-right harness, or `nil` when it is
    /// not enabled for this process.
    public var splitCloseRight: SplitCloseRightConfig?

    /// Configuration for the child-exit split harness, or `nil` when it is not
    /// enabled for this process.
    public var childExitSplit: ChildExitSplitConfig?

    /// Configuration for the child-exit keyboard harness, or `nil` when it is
    /// not enabled for this process.
    public var childExitKeyboard: ChildExitKeyboardConfig?

    /// Creates a plan from its components. Callers normally obtain a plan from
    /// ``UITestSplitScaffoldGate/plan(from:)`` rather than constructing it here.
    public init(
        installsFocusShortcuts: Bool = false,
        splitCloseRight: SplitCloseRightConfig? = nil,
        childExitSplit: ChildExitSplitConfig? = nil,
        childExitKeyboard: ChildExitKeyboardConfig? = nil
    ) {
        self.installsFocusShortcuts = installsFocusShortcuts
        self.splitCloseRight = splitCloseRight
        self.childExitSplit = childExitSplit
        self.childExitKeyboard = childExitKeyboard
    }

    /// `true` when no scaffold is enabled, so the caller can skip all setup.
    public var isEmpty: Bool {
        !installsFocusShortcuts
            && splitCloseRight == nil
            && childExitSplit == nil
            && childExitKeyboard == nil
    }

    /// Parsed configuration for the split-then-close-right harness.
    ///
    /// Mirrors the legacy `setupSplitCloseRightUITestIfNeeded` env parsing:
    /// `path` is the capture file, `visualMode` selects the IOSurface-timeline
    /// repro, and the numeric knobs clamp their env values exactly as before
    /// (the wider clamps applied just before driving the visual repro stay in
    /// the app body).
    public struct SplitCloseRightConfig: Sendable, Equatable {
        public var path: String
        public var visualMode: Bool
        public var shotsDir: String
        public var visualIterations: Int
        public var burstFrames: Int
        public var closeDelayMs: Int
        public var pattern: String

        public init(
            path: String,
            visualMode: Bool,
            shotsDir: String,
            visualIterations: Int,
            burstFrames: Int,
            closeDelayMs: Int,
            pattern: String
        ) {
            self.path = path
            self.visualMode = visualMode
            self.shotsDir = shotsDir
            self.visualIterations = visualIterations
            self.burstFrames = burstFrames
            self.closeDelayMs = closeDelayMs
            self.pattern = pattern
        }
    }

    /// Parsed configuration for the child-exit split harness.
    ///
    /// Mirrors the legacy `setupChildExitSplitUITestIfNeeded` env parsing:
    /// `iterations` is clamped to `1...20` exactly as the legacy body did.
    public struct ChildExitSplitConfig: Sendable, Equatable {
        public var path: String
        public var requestedIterations: Int
        public var iterations: Int

        public init(path: String, requestedIterations: Int, iterations: Int) {
            self.path = path
            self.requestedIterations = requestedIterations
            self.iterations = iterations
        }
    }

    /// Parsed configuration for the child-exit keyboard harness.
    ///
    /// Mirrors the legacy `setupChildExitKeyboardUITestIfNeeded` env parsing,
    /// including the trigger-mode booleans derived from
    /// `CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE` and the
    /// `expectedPanelsAfter` floor of 1.
    public struct ChildExitKeyboardConfig: Sendable, Equatable {
        public var path: String
        public var autoTrigger: Bool
        public var strictKeyOnly: Bool
        public var triggerMode: String
        public var useEarlyCtrlShiftTrigger: Bool
        public var useEarlyCtrlDTrigger: Bool
        public var useEarlyTrigger: Bool
        public var triggerUsesShift: Bool
        public var layout: String
        public var expectedPanelsAfter: Int

        public init(
            path: String,
            autoTrigger: Bool,
            strictKeyOnly: Bool,
            triggerMode: String,
            useEarlyCtrlShiftTrigger: Bool,
            useEarlyCtrlDTrigger: Bool,
            useEarlyTrigger: Bool,
            triggerUsesShift: Bool,
            layout: String,
            expectedPanelsAfter: Int
        ) {
            self.path = path
            self.autoTrigger = autoTrigger
            self.strictKeyOnly = strictKeyOnly
            self.triggerMode = triggerMode
            self.useEarlyCtrlShiftTrigger = useEarlyCtrlShiftTrigger
            self.useEarlyCtrlDTrigger = useEarlyCtrlDTrigger
            self.useEarlyTrigger = useEarlyTrigger
            self.triggerUsesShift = triggerUsesShift
            self.layout = layout
            self.expectedPanelsAfter = expectedPanelsAfter
        }
    }
}
