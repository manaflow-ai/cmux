/// The deterministic run/dismiss sequence for activating one palette command.
///
/// Activating a command interleaves two host side effects in a fixed order:
/// running the command's action and dismissing the palette (optionally restoring
/// focus to a captured target). Which of dismiss/run comes first, and whether
/// dismissal happens at all, is a pure function of the command's `dismissOnRun`
/// flag, whether the command must dismiss *before* running (a small per-command
/// policy the host supplies), and whether a post-run focus target was captured.
///
/// The host owns the side effects (they touch live `@State`, AppKit focus, and
/// usage history); this value owns only the *ordering decision*, so the legacy
/// `runCommandPaletteCommand` control flow is reproduced byte-for-byte while the
/// branch logic lives in the palette domain where it is unit-testable.
///
/// ## Faithful mapping
///
/// The legacy ``ContentView`` body was:
///
/// ```swift
/// recordUsage()
/// if dismissOnRun && shouldDismissBeforeRun {
///     dismiss(restoreFocus: hasFocusTarget, target: focusTarget)
///     action()
///     return
/// }
/// action()
/// if dismissOnRun {
///     dismiss(restoreFocus: hasFocusTarget, target: focusTarget)
/// }
/// ```
///
/// Usage is always recorded first by the host; ``steps`` reproduces the
/// remaining branch exactly.
public struct CommandPaletteCommandRunPlan: Sendable, Equatable {
    /// One ordered side effect the host performs when activating a command.
    public enum Step: Sendable, Equatable {
        /// Run the command's action closure.
        case run
        /// Dismiss the palette. `restoreFocus` mirrors the legacy
        /// `dismissCommandPalette(restoreFocus:preferredFocusTarget:)` call,
        /// which restores focus exactly when a post-run focus target exists.
        case dismiss(restoreFocus: Bool)
    }

    /// The ordered steps the host performs after recording usage.
    public let steps: [Step]

    /// Builds the plan for activating a command.
    ///
    /// - Parameters:
    ///   - dismissOnRun: Whether the command dismisses the palette on run.
    ///   - dismissBeforeRun: Whether the command must dismiss before its action
    ///     runs (synchronous-focus commands), as decided by the host's
    ///     per-command policy. Only consulted when `dismissOnRun` is `true`.
    ///   - hasFocusTarget: Whether a post-run focus target was captured. Drives
    ///     the `restoreFocus` flag on any `dismiss` step.
    public init(
        dismissOnRun: Bool,
        dismissBeforeRun: Bool,
        hasFocusTarget: Bool
    ) {
        guard dismissOnRun else {
            steps = [.run]
            return
        }
        if dismissBeforeRun {
            steps = [.dismiss(restoreFocus: hasFocusTarget), .run]
        } else {
            steps = [.run, .dismiss(restoreFocus: hasFocusTarget)]
        }
    }
}
