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

    /// Whether the operation keeps a page in a covered window that is still on a screen, instead
    /// of moving it into its off-screen render window: a wheel. WebKit runs a trusted native wheel
    /// only in a window on a screen, and the render window lies outside every screen.
    public var needsAScreen: Bool {
        if case .input(.wheel) = self { true } else { false }
    }
}
