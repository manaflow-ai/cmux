/// Where `cmux open-remote` puts the terminal: a tab of the pane or a split of it.
/// A terminal of another machine splits right or down only, so `left`, `top` and
/// `window` are refused rather than guessed.
public nonisolated enum OpenRemotePlacement: Sendable, Hashable {
    case tab, right, down
}
