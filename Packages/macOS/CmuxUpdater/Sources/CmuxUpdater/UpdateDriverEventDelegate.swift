import Foundation
@preconcurrency import Sparkle

/// Causal lifecycle signals that do not belong in `SPUUserDriver`'s display states.
///
/// The controller owns check/install intent. The driver forwards authoritative Sparkle callbacks
/// and its bounded check deadline so the controller can resolve each signal in that intent.
@MainActor
protocol UpdateDriverEventDelegate: AnyObject {
    /// Sparkle ended an update session, so a queued replacement check may safely start.
    func updateDriverDidFinishCycle(_ updateCheck: SPUUpdateCheck, error: NSError?)

    /// The user explicitly cancelled the foreground check.
    func updateDriverUserDidCancelCheck()

    /// The user explicitly dismissed or skipped a foreground update prompt.
    func updateDriverUserDidDismissPrompt()

    /// The foreground check produced no Sparkle result before the driver's bounded deadline.
    func updateDriverCheckDidTimeOut()
}
