import SwiftUI

/// Browser adapter for the shared WebKit-panel find bar.
struct BrowserSearchOverlay: View {
    @ObservedObject var searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let selectAllOnFocusRequest: Bool
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void

    var body: some View {
        WebViewFindBar(
            needle: $searchState.needle,
            selected: searchState.selected,
            total: searchState.total,
            accessibilityIdentifier: "BrowserFindSearchTextField",
            focusRequestGeneration: focusRequestGeneration,
            selectAllOnFocusRequest: selectAllOnFocusRequest,
            selectionOwner: searchState,
            canApplyFocusRequest: canApplyFocusRequest,
            onFieldDidFocus: onFieldDidFocus,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose
        )
    }
}
