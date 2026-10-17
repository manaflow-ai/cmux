public import Foundation

/// A browser panel of the active workspace, as ``ChromiumUnownedTabPlacement``
/// sees it.
public struct ChromiumUnownedTabCandidate: Equatable, Sendable {
    public var panelID: UUID
    public var paneID: UUID
    public var profileID: UUID
    /// The panel shows a live Chromium page.
    public var isChromium: Bool
    /// The panel is the workspace's focused panel.
    public var isFocused: Bool
    /// The panel is its pane's selected tab.
    public var isSelectedInPane: Bool

    public init(panelID: UUID, paneID: UUID, profileID: UUID, isChromium: Bool, isFocused: Bool, isSelectedInPane: Bool) {
        self.panelID = panelID
        self.paneID = paneID
        self.profileID = profileID
        self.isChromium = isChromium
        self.isFocused = isFocused
        self.isSelectedInPane = isSelectedInPane
    }
}

/// Where a tab Chromium opens for no cmux page lands: an extension's
/// `chrome.tabs.create` from its background worker, the welcome page an
/// extension opens after its install, a tab created before any Chromium
/// page exists. The same page shows a download such a worker starts.
///
/// The focused Chromium page of the active workspace (else a shown one) of
/// the request's profile takes it into its Chromium window, so the extension
/// keeps a real tab; the tab then opens beside that page like a link's tab.
/// Without one, the URL opens as a new Chromium tab in the focused browser
/// pane, else in a new browser pane.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFOrphanTabs.swift` and
/// `CEFWindowPolicy.swift` (the last shown pane window takes the tab).
public enum ChromiumUnownedTabPlacement {
    /// The panel whose Chromium page takes the tab; `profile` nil accepts any
    /// profile (a download, whose profile Chromium does not report).
    public static func anchor(among candidates: [ChromiumUnownedTabCandidate], profile: UUID?) -> UUID? {
        let eligible = candidates.filter {
            $0.isChromium && $0.isSelectedInPane && (profile == nil || $0.profileID == profile)
        }
        return (eligible.first(where: \.isFocused) ?? eligible.first)?.panelID
    }

    /// The pane a new tab opens in when no page takes it: the focused browser
    /// pane, else a pane showing a browser; nil opens a new pane.
    public static func pane(among candidates: [ChromiumUnownedTabCandidate]) -> UUID? {
        let shown = candidates.filter(\.isSelectedInPane)
        return (shown.first(where: \.isFocused) ?? shown.first)?.paneID
    }

    /// How a new Chromium tab beside its opener takes focus.
    public enum NewTabFocus: Equatable, Sendable {
        /// Selected and focused (a link the person opened).
        case focus
        /// Selected in its pane; focused only when its pane already has the
        /// keyboard, so it never pulls focus out of another pane.
        case selectFocusingOnlyAFocusedPane
        /// Opens behind the selected tab.
        case background
    }

    /// A foreground tab nobody clicked for (an extension's tab, a script's
    /// `window.open`) never takes the keyboard from another pane.
    public static func newTabFocus(foreground: Bool, userGesture: Bool) -> NewTabFocus {
        guard foreground else { return .background }
        return userGesture ? .focus : .selectFocusingOnlyAFocusedPane
    }
}
