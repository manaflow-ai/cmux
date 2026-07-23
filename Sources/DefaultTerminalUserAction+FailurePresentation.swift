import AppKit

extension DefaultTerminalUserAction {
    enum FailurePresentation {
        case alert(presentingWindow: NSWindow?)
        case silent
    }
}
