enum BrowserAutomationProbeChannel: Sendable {
    case javaScript
    case snapshot

    var debugName: String {
        switch self {
        case .javaScript: "javascript"
        case .snapshot: "snapshot"
        }
    }
}
