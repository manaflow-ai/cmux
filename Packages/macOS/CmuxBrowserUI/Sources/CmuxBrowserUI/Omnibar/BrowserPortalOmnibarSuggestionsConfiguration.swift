public import CmuxBrowser
public import Foundation
public import SwiftUI

/// Inputs the in-window browser portal needs to mount the omnibar suggestion
/// popup for one panel.
///
/// A plain value bundle of the suggestion rows, popup placement, and the commit
/// and highlight callbacks the popup invokes. The portal builds this from the
/// owning panel's omnibar state and hands it to the suggestions host;
/// `popupFrame` is in the portal's top-left coordinate space. This type holds
/// closures, so it is not `Sendable` and is used only on the main actor.
public struct BrowserPortalOmnibarSuggestionsConfiguration {
    /// Identifier of the browser panel the popup belongs to.
    public let panelId: UUID

    /// Popup frame in the portal's top-left coordinate space.
    public let popupFrame: CGRect

    /// Color scheme the popup renders with.
    public let colorScheme: ColorScheme

    /// Active search engine name shown in search rows.
    public let engineName: String

    /// Ordered suggestion rows to render.
    public let items: [OmnibarSuggestion]

    /// Index of the highlighted row.
    public let selectedIndex: Int

    /// Whether remote suggestions are still in flight.
    public let isLoadingRemoteSuggestions: Bool

    /// Whether remote search suggestions are enabled.
    public let searchSuggestionsEnabled: Bool

    /// Invoked when a suggestion row is activated.
    public let onCommit: (OmnibarSuggestion) -> Void

    /// Invoked when a row should become the selection.
    public let onHighlight: (Int) -> Void

    /// Creates an omnibar suggestions popup configuration.
    /// - Parameters:
    ///   - panelId: Identifier of the owning browser panel.
    ///   - popupFrame: Popup frame in the portal's top-left coordinate space.
    ///   - colorScheme: Color scheme to render with.
    ///   - engineName: Active search engine name.
    ///   - items: Ordered suggestion rows to render.
    ///   - selectedIndex: Index of the highlighted row.
    ///   - isLoadingRemoteSuggestions: Whether remote suggestions are in flight.
    ///   - searchSuggestionsEnabled: Whether remote search suggestions are enabled.
    ///   - onCommit: Invoked when a row is activated.
    ///   - onHighlight: Invoked when a row should become the selection.
    public init(
        panelId: UUID,
        popupFrame: CGRect,
        colorScheme: ColorScheme,
        engineName: String,
        items: [OmnibarSuggestion],
        selectedIndex: Int,
        isLoadingRemoteSuggestions: Bool,
        searchSuggestionsEnabled: Bool,
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping (Int) -> Void
    ) {
        self.panelId = panelId
        self.popupFrame = popupFrame
        self.colorScheme = colorScheme
        self.engineName = engineName
        self.items = items
        self.selectedIndex = selectedIndex
        self.isLoadingRemoteSuggestions = isLoadingRemoteSuggestions
        self.searchSuggestionsEnabled = searchSuggestionsEnabled
        self.onCommit = onCommit
        self.onHighlight = onHighlight
    }

    /// Returns whether this configuration is equivalent to `other` for mount
    /// reuse, comparing only the value fields that affect what the suggestion
    /// popup renders. The closures are ignored: a difference in callbacks does
    /// not require remounting the popup. ``popupFrame`` is compared with a 0.5pt
    /// tolerance so sub-pixel layout jitter does not force a remount.
    /// - Parameter other: The configuration to compare against.
    /// - Returns: `true` when both configurations target the same panel, render
    ///   the same rows in the same state, and place the popup at approximately
    ///   the same frame.
    public func isEquivalent(to other: BrowserPortalOmnibarSuggestionsConfiguration) -> Bool {
        let frame = popupFrame
        let otherFrame = other.popupFrame
        let epsilon: CGFloat = 0.5
        let frameApproximatelyEqual = abs(frame.origin.x - otherFrame.origin.x) <= epsilon &&
            abs(frame.origin.y - otherFrame.origin.y) <= epsilon &&
            abs(frame.size.width - otherFrame.size.width) <= epsilon &&
            abs(frame.size.height - otherFrame.size.height) <= epsilon
        return panelId == other.panelId &&
            frameApproximatelyEqual &&
            colorScheme == other.colorScheme &&
            engineName == other.engineName &&
            items == other.items &&
            selectedIndex == other.selectedIndex &&
            isLoadingRemoteSuggestions == other.isLoadingRemoteSuggestions &&
            searchSuggestionsEnabled == other.searchSuggestionsEnabled
    }
}
