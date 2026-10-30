/// Chromium's page accessibility, on while an assistive client asks for the app's tree.
/// Chromium builds a page's accessibility tree only when its embedder says so
/// (`CefBrowserHost::SetAccessibilityState`); the app tells this when VoiceOver or an automation
/// driver asks (`CmuxApplication`, `AssistiveClientRequests`), and every Chromium page, open now
/// or opened later, follows it. Off, a page's window is an AXWindow with nothing in it.
@MainActor
final class CEFAccessibility {
    private(set) var isEnabled = false
    private let apply: (Int32, Bool) -> Void
    private let browsers: () -> [Int32]

    /// - Parameters:
    ///   - apply: Sets one browser's accessibility.
    ///   - browsers: The open browsers.
    init(apply: @escaping (Int32, Bool) -> Void, browsers: @escaping () -> [Int32]) {
        self.apply = apply
        self.browsers = browsers
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        for browser in browsers() { apply(browser, enabled) }
    }

    /// A browser that just opened: on when accessibility is.
    func attached(_ browser: Int32) {
        if isEnabled { apply(browser, true) }
    }
}
