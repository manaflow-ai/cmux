/// Where a toast rests in its window (``CmuxToastLook/placement``).
public nonisolated enum CmuxToastPlacement: String, Sendable, Hashable {
    /// Bottom center, the newest lowest (the toasts' place since R96).
    case bottomCenter
    /// Bottom trailing corner, out of the middle of the work, the newest lowest.
    case bottomTrailing
}
