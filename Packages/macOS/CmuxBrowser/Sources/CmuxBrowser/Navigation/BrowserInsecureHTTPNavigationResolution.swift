public enum BrowserInsecureHTTPNavigationResolution {
    case openedExternally
    case proceededInCurrentTab
    case proceededInNewTab
    case cancelled

    public var isTerminalPolicyCancellation: Bool {
        switch self {
        case .openedExternally, .proceededInNewTab:
            true
        case .proceededInCurrentTab, .cancelled:
            false
        }
    }
}
