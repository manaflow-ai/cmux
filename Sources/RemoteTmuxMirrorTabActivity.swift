struct RemoteTmuxMirrorTabActivity {
    let hasActiveCommand: Bool

    /// The first active pane's foreground command, or `nil` when idle or unnamed.
    let activeCommandName: String?
}
