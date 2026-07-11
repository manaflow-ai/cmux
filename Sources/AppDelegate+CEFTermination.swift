import AppKit
import CEFKit

/// Termination gates for the Chromium (CEF) debug browser. Chromium's close
/// handshake cannot complete while an AppKit terminate request is pending,
/// and its atexit handlers crash the exiting process (SIGTRAP) even after a
/// clean browser drain — so quitting drains CEF browsers on the live run
/// loop first and finalizes the process exit last. Every gate is a no-op
/// unless the CEF debug browser was used this session.
extension AppDelegate {
    /// Dialog path: the user confirmed quit. Marks the quit confirmed (so
    /// the re-initiated termination skips the dialog); when CEF browsers
    /// are open, replies false to release this terminate request while they
    /// drain and returns false. Otherwise runs the confirmed-termination
    /// preparation and returns true.
    func cefGateConfirmedQuitAndPrepare() -> Bool {
        isQuitWarningConfirmed = true
        if CEFRuntimeSupport.prepareForApplicationTermination() {
            prepareForConfirmedAppTermination()
            return true
        }
        StartupBreadcrumbLog.append("appDelegate.shouldTerminate.cefDrainAfterConfirm")
        replyToTerminateOnce(false)
        return false
    }

    /// Committed path (no dialog will be shown): drains CEF browsers before
    /// termination proceeds, then runs the confirmed-termination
    /// preparation. Returns false when this terminate request must be
    /// cancelled; termination is re-initiated once the drain completes.
    func cefGateCommittedTerminationAndPrepare() -> Bool {
        if CEFRuntimeSupport.prepareForApplicationTermination() {
            prepareForConfirmedAppTermination()
            return true
        }
        StartupBreadcrumbLog.append("appDelegate.shouldTerminate.cefDrain")
        return false
    }

    /// Must run last in applicationWillTerminate: when the CEF debug
    /// browser was used this session the process ends here, skipping
    /// Chromium's crashing atexit handlers.
    func cefFinalizeProcessExit() {
        CEFApp.shared.finalizeProcessExitIfNeeded()
    }
}
