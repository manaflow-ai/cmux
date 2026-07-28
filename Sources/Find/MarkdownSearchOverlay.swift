import Observation
import SwiftUI

/// Find bar layered over a markdown panel's rendered WebView.
struct MarkdownSearchOverlay: View {
    @Bindable var controller: MarkdownFindController
    let onClose: () -> Void

    var body: some View {
        if let searchState = controller.searchState {
            WebViewFindBar(
                needle: Binding(
                    get: { searchState.needle },
                    set: { _ = controller.updateNeedle($0) }
                ),
                selected: searchState.selected,
                total: searchState.total,
                accessibilityIdentifier: "MarkdownFindSearchTextField",
                focusRequestGeneration: controller.focusRequestGeneration,
                selectAllOnFocusRequest: controller.selectAllOnFocusRequest,
                selectionOwner: searchState,
                canApplyFocusRequest: controller.canApplyFocusRequest,
                onFieldDidFocus: {},
                onNext: { _ = controller.findNext() },
                onPrevious: { _ = controller.findPrevious() },
                onClose: onClose
            )
        }
    }
}
