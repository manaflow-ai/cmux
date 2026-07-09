/// Decision for routing a key event while browser focus mode is being evaluated.
public enum BrowserFocusModeKeyDecision: Equatable {
    case inactive
    case forwardToWebView
    case consume
}
