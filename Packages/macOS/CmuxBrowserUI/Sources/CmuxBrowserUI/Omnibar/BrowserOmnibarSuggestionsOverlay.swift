public import SwiftUI

/// The SwiftUI omnibar-suggestions overlay: hosts ``OmnibarSuggestionsView`` and
/// anchors it just below the omnibar pill, sized to the pill width and pinned
/// above sibling chrome via a high `zIndex`.
///
/// Renders from a ``BrowserOmnibarSuggestionsSnapshot`` and routes taps through
/// ``BrowserOmnibarSuggestionsActions``. The app-side forwarder gates whether the
/// overlay is mounted (SwiftUI vs the AppKit portal-hosted path) and builds the
/// snapshot/actions; the omnibar text-field host and suggestion commit logic stay
/// app-side.
public struct BrowserOmnibarSuggestionsOverlay: View {
    private let snapshot: BrowserOmnibarSuggestionsSnapshot
    private let actions: BrowserOmnibarSuggestionsActions

    /// Creates the omnibar-suggestions overlay from a snapshot and action bundle.
    public init(
        snapshot: BrowserOmnibarSuggestionsSnapshot,
        actions: BrowserOmnibarSuggestionsActions
    ) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        OmnibarSuggestionsView(
            engineName: snapshot.engineName,
            items: snapshot.items,
            badges: snapshot.badges,
            selectedIndex: snapshot.selectedIndex,
            isLoadingRemoteSuggestions: snapshot.isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: snapshot.searchSuggestionsEnabled,
            accessibilityLabel: snapshot.accessibilityLabel,
            onCommit: actions.onCommit,
            onHighlight: actions.onHighlight
        )
        .frame(width: snapshot.pillFrame.width)
        .offset(x: snapshot.pillFrame.minX, y: snapshot.pillFrame.maxY + 3)
        .zIndex(1000)
        .environment(\.colorScheme, snapshot.colorScheme)
    }
}
