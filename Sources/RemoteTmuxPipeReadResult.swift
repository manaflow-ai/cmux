/// The outcome of one nonblocking read from a remote-tmux process pipe.
enum RemoteTmuxPipeReadResult: Equatable {
    case published
    case interrupted
    case wouldBlock
    case ended
}
