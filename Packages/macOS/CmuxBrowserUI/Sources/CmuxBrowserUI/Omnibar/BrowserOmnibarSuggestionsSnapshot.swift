public import CmuxBrowser
public import CoreGraphics
public import SwiftUI

/// Pure value snapshot driving the SwiftUI omnibar-suggestions overlay: the
/// search-engine display name, the suggestion list and selected index, the
/// remote-suggestion loading/enabled flags, the omnibar pill frame the popup
/// anchors below, the chrome color scheme, and the pre-resolved accessibility
/// label.
///
/// Every field is resolved app-side. The accessibility label comes from an
/// app-bundle `String(localized:)`, and the suggestions/selection are read off
/// the panel's omnibar state, so the overlay renders here without reaching back
/// into the app target.
public struct BrowserOmnibarSuggestionsSnapshot: Sendable {
    /// Display name of the active search engine, shown to assistive tech rows.
    public var engineName: String
    /// The ordered suggestion rows to render.
    public var items: [OmnibarSuggestion]
    /// Pre-localized trailing badge per row, index-aligned with ``items`` (`nil`
    /// for rows without a badge). Resolved app-side because the badge text binds
    /// to the app bundle's string catalog.
    public var badges: [String?]
    /// Index of the highlighted suggestion row.
    public var selectedIndex: Int
    /// Whether a remote-suggestion fetch is in flight (drives the spinner).
    public var isLoadingRemoteSuggestions: Bool
    /// Whether remote search suggestions are enabled (gates the spinner).
    public var searchSuggestionsEnabled: Bool
    /// The omnibar pill frame in the panel coordinate space; the popup is sized
    /// to its width and offset just below its bottom edge.
    public var pillFrame: CGRect
    /// Chrome color scheme to force on the popup independent of the system one.
    public var colorScheme: ColorScheme
    /// Pre-localized accessibility label for the suggestions container.
    public var accessibilityLabel: String

    /// Creates the omnibar-suggestions snapshot from values resolved app-side.
    public init(
        engineName: String,
        items: [OmnibarSuggestion],
        badges: [String?],
        selectedIndex: Int,
        isLoadingRemoteSuggestions: Bool,
        searchSuggestionsEnabled: Bool,
        pillFrame: CGRect,
        colorScheme: ColorScheme,
        accessibilityLabel: String
    ) {
        self.engineName = engineName
        self.items = items
        self.badges = badges
        self.selectedIndex = selectedIndex
        self.isLoadingRemoteSuggestions = isLoadingRemoteSuggestions
        self.searchSuggestionsEnabled = searchSuggestionsEnabled
        self.pillFrame = pillFrame
        self.colorScheme = colorScheme
        self.accessibilityLabel = accessibilityLabel
    }
}
