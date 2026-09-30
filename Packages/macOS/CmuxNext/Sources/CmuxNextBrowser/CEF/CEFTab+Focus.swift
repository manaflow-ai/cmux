import Foundation

/// Where a Chromium focus request comes from (`cef_focus_source_t`).
nonisolated enum CEFFocusSource: Int32, Sendable {
    /// CEF focuses a page after it navigates it: the first load of a new
    /// browser (`ChromeBrowserHostImpl::Create`) and every `LoadURL`.
    case navigation = 0
    /// `CefBrowserHost::SetFocus(true)`, which cmux itself calls.
    case system = 1

    var name: String {
        switch self {
        case .navigation: "navigation"
        case .system: "system"
        }
    }
}

extension CEFTab {
    /// Chromium asks to focus this page (`CefFocusHandler::OnSetFocus`).
    /// Today the shim installs no focus handler, so every request wins.
    func chromiumRequestsFocus(_ source: CEFFocusSource) -> Bool {
        true
    }
}
