public import Foundation

/// A page's back/forward history with page state, in its engine's format.
public enum BrowserPageRestoreState: Equatable, Hashable, Sendable {
    /// `WKWebView.interactionState`, archived.
    case webKit(Data)
    /// The Chromium navigation state string.
    case chromium(String)

    /// The engine that can read this state.
    public var engineKind: BrowserEngineKind {
        switch self {
        case .webKit: .webkit
        case .chromium: .chromium
        }
    }
}
