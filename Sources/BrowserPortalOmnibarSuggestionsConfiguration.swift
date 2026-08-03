import CmuxAppKitSupportUI
import CoreGraphics
import Foundation

struct BrowserPortalOmnibarSuggestionsConfiguration {
    let panelId: UUID
    let popupFrame: CGRect
    let colorScheme: WindowChromeColorScheme
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
}
