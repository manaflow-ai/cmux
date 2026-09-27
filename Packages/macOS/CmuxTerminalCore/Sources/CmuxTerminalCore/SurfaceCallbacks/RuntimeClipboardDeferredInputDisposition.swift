/// Selects how invalidation handles input buffered behind a native clipboard request.
public enum RuntimeClipboardDeferredInputDisposition: Sendable {
    /// Replays input after a live request fails or is cancelled.
    case replay

    /// Discards input owned by a runtime surface that is no longer safe to target.
    case discard
}
