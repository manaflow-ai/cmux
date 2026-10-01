public enum BrowserAutomationProbeChannel: Sendable {
    case javaScript
    case screenshot

    public var debugName: String {
        switch self {
        case .javaScript: "javascript"
        case .screenshot: "screenshot"
        }
    }
}
