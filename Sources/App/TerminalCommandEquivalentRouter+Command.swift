extension TerminalCommandEquivalentRouter {
    enum Command: String, Equatable {
        case copy
        case paste
        case cut
        case selectAll
    }
}
