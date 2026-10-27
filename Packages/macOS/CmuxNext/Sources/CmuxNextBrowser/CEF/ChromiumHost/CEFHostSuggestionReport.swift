public import AppKit

/// One page view's shown suggestions, for `debug.cef` `host_suggestions` (chromium-host-bench.py
/// `--native-ui` autofill and password rows, task 061).
public struct CEFHostSuggestionReport: Equatable, Sendable {
    public let browser: Int32
    public let token: Int64
    /// Each row's kind: `entry`, `separator`, `title` or `footer`.
    public let kinds: [String]
    /// Each row's Chromium `autofill::SuggestionType`.
    public let types: [Int]
    /// The row Chromium's keys or the pointer selected, nil for none.
    public let highlighted: Int?
    /// The list's card on the screen (AppKit origin), nil while it is not on screen.
    public let screenFrame: CGRect?
    /// The rows' field on the screen (AppKit origin), nil while its page view is in no window.
    public let field: CGRect?
}

extension ChromiumHostSuggestionList {
    /// The shown rows, nil while none show.
    var report: CEFHostSuggestionReport? {
        guard let shown else { return nil }
        let rows = shown.suggestions.rows
        return CEFHostSuggestionReport(browser: shown.browser, token: shown.suggestions.token, kinds: rows.map { "\($0.kind)" },
                                       types: rows.map(\.type), highlighted: shown.highlighted, screenFrame: shownFrame,
                                       field: fieldOnScreen)
    }
}

extension CEFEngine {
    /// Every page view's shown suggestions; nil unless the host draws them in cmux
    /// (``CEFRuntime/drawsSuggestionsInCmux``).
    public var hostSuggestions: [CEFHostSuggestionReport]? {
        let runtime = CEFRuntime.shared
        guard runtime.drawsSuggestionsInCmux else { return nil }
        return runtime.hosts.values.compactMap { $0.hostedPageView?.suggestions.report }
    }
}
