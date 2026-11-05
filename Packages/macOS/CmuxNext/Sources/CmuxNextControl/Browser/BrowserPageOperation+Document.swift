extension BrowserPageOperation {
    /// Whether the operation acts on the page's document, so a page no window shows first renders
    /// off screen (animation frames, timers at full rate, native input; nothing shown, no focus
    /// moved). `state` reads the tab's record and `cookies` the profile's store: neither does.
    public var actsOnDocument: Bool {
        switch self {
        case .state, .cookies: false
        case .navigate, .back, .forward, .reload, .evaluate, .evaluateAsync, .screenshot, .input, .upload: true
        }
    }
}
