/// The result of one focus-restore attempt against a pending dismiss target.
///
/// Returned by a ``CommandPaletteFocusGuard`` so the owning
/// ``CommandPaletteFocusRestoreController`` knows whether to clear the pending
/// target (and cancel its timeout) or keep waiting for a later retry trigger.
///
/// This reproduces the three terminal states of the previous inline
/// `attemptCommandPaletteFocusRestoreIfNeeded` body:
///
/// - ``paletteStillPresented``: the palette has not finished dismissing, so the
///   attempt is a no-op and the pending target is retained.
/// - ``targetUnavailable``: the target's workspace no longer exists, so the
///   pending target is cleared and the timeout cancelled without restoring.
/// - ``retryLater``: the window/tab focus was driven but the target panel did
///   not become the focused responder yet, so the pending target is retained
///   for the next retry trigger (or the timeout).
/// - ``restored``: the target panel regained keyboard focus, so the pending
///   target is cleared and the timeout cancelled.
public enum CommandPaletteFocusRestoreOutcome: Sendable, Equatable {
    /// The palette is still visible; the attempt did nothing and the pending
    /// target is kept.
    case paletteStillPresented

    /// The target workspace is gone; clear the pending target without restoring.
    case targetUnavailable

    /// Focus was driven but the target panel is not focused yet; keep waiting.
    case retryLater

    /// The target panel regained focus; clear the pending target.
    case restored
}
