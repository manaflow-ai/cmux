#if DEBUG
public import CmuxMobileShellModel

/// The seam ``DogfoodFeedbackModel`` uses to capture and send a feedback bundle.
///
/// The concrete implementation lives in the UI layer, where the chrome
/// screenshot (`drawHierarchy`), the visible terminal text
/// (`GhosttySurfaceView.visibleTerminalSnapshot()`), and the debug-log snapshot
/// (`MobileDebugLog`) are reachable; it gathers those, attaches the supplied
/// multiple-choice answers + note, and forwards to the shell's
/// `dogfood.feedback.submit` path. Injecting it keeps the model testable with a
/// fake submitter and avoids the model reaching across modules for UIKit/terminal
/// accessors.
///
/// DEBUG-only; absent in release builds.
@MainActor
public protocol DogfoodFeedbackSubmitting: AnyObject {
    /// Capture the current screen + terminal + diagnostics, attach the answers,
    /// and submit to the paired Mac.
    /// - Parameter answers: The multiple-choice answers + freeform note.
    /// - Returns: `true` when the Mac acknowledged the bundle.
    func submit(answers: DogfoodFeedbackAnswers) async -> Bool
}
#endif
