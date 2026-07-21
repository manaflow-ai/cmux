import Foundation
@preconcurrency import Sparkle

/// Causal lifecycle signals that Sparkle exposes outside of `SPUUserDriver`'s display states.
///
/// The controller owns check/install intent. The driver forwards these signals so that intent is
/// advanced by authoritative callbacks instead of inferred from UI state or elapsed time.
@MainActor
protocol UpdateDriverEventDelegate: AnyObject {
    /// Sparkle ended an update session, so a queued replacement check may safely start.
    func updateDriverDidFinishCycle(_ updateCheck: SPUUpdateCheck, error: NSError?)

    /// Sparkle is about to present a no-update result. Snapshot the originating operation so an
    /// indeterminate result can retry without downgrading an accepted install.
    func updateDriverWillPresentNoUpdate()

    /// Sparkle is about to present an error. Snapshot the operation intent before the model's
    /// error state ends any active coordinator lifecycle.
    func updateDriverDidPresentError()

    /// The user asked to retry the Sparkle operation that produced the current error.
    func updateDriverRequestsRetryAfterError()

    /// The user dismissed the current Sparkle error.
    func updateDriverDidDismissError()

    /// The user explicitly cancelled the foreground check.
    func updateDriverUserDidCancelCheck()

    /// The user explicitly dismissed or skipped a foreground update prompt.
    func updateDriverUserDidDismissPrompt()
}
