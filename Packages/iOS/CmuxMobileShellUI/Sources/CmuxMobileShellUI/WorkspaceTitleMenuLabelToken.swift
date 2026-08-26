enum WorkspaceTitleMenuLabelToken: Equatable {
    /// `isReconnecting` swaps the title's leading dot for a spinner while the
    /// workspace's connection is being reestablished, and participates in
    /// equality so the memoized toolbar label re-renders on that transition.
    case standard(title: String, subtitle: String?, isReconnecting: Bool)
}
