import Foundation

/// Shape common to every panel that hosts a web-rendering engine —
/// today either ``BrowserPanel`` (WKWebView) or ``CEFBrowserPanel``
/// (Chromium Embedded Framework).
///
/// The `Panel` protocol covers the lifecycle bits the workspace and tab
/// strip care about. This narrower protocol adds the two fields cmux
/// reads when constructing a Bonsplit tab for a browser surface
/// (``isLoading`` for the tab spinner) or when persisting the pane
/// across sessions (``profileID`` for cookie / extension isolation).
///
/// Keeping this protocol minimal preserves the existing
/// ``BrowserPanel`` API exactly. CEF-specific functionality (extension
/// management, dev tools docking, etc.) does **not** belong here.
@MainActor
protocol BrowserEngineBackedPanel: Panel {
    /// Per-pane profile identifier. Maps to a `WKWebsiteDataStore`
    /// (WKWebView) or `CefRequestContext` (CEF). Same workspace can
    /// host multiple panes sharing one profileID; different profileIDs
    /// produce fully isolated browsing state.
    var profileID: UUID { get }

    /// True while a navigation is in flight. cmux's Bonsplit tab uses
    /// this to render the per-tab loading spinner.
    var isLoading: Bool { get }
}

// MARK: - BrowserPanel already satisfies the protocol shape via its
// existing `@Published private(set) var profileID: UUID` and
// `@Published private(set) var isLoading: Bool`. Declare the
// conformance in a one-line extension so this PR's surgical diff to
// `BrowserPanel.swift` stays zero — the original 10 800-line file is
// not touched.
extension BrowserPanel: BrowserEngineBackedPanel {}
