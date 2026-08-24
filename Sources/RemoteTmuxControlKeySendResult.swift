/// Outcome of translating and forwarding one control-plane key to tmux.
enum RemoteTmuxControlKeySendResult {
    case sent
    case rejected
    case unknownKey
}
