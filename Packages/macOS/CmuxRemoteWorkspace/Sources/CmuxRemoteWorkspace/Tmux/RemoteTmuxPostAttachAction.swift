public enum RemoteTmuxPostAttachAction {
    /// Reconnect: re-seed every mirrored pane after the fresh client lost the
    /// screen, subscriptions, and client size.
    case reseed

    /// First connect: re-apply a client grid stored before stdin was live, so
    /// the remote does not stay at ssh's default 80x24.
    case applyClientSize
}
