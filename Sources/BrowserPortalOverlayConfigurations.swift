import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


struct BrowserPortalSearchOverlayConfiguration {
    let panelId: UUID
    let searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void
}

struct BrowserPortalOmnibarSuggestionsConfiguration {
    let panelId: UUID
    let popupFrame: CGRect
    let colorScheme: ColorScheme
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
}

