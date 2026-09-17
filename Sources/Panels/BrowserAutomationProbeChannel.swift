enum BrowserAutomationProbeChannel: Sendable {
    case javaScript
    case screenshot

    var debugName: String {
        switch self {
        case .javaScript: "javascript"
        case .screenshot: "screenshot"
        }
    }
}
