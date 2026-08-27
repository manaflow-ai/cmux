/// The tmux command whose asynchronous topology event will materialize a routed creation.
enum ControlRemoteTmuxCreationOperation: String, Sendable {
    case newWindow = "new-window"
    case splitWindow = "split-window"
}
