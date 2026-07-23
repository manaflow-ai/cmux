extension TerminalPanel {
    enum TextBoxInputRequestResult: Equatable {
        case focused
        case queued
        case hidden
        case failed

        var accepted: Bool {
            self != .failed
        }
    }
}
