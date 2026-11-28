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

    /// The user explicitly cancelled the foreground check.
    func updateDriverUserDidCancelCheck()

    /// The user explicitly dismissed or skipped a foreground update prompt.
    func updateDriverUserDidDismissPrompt()
}
