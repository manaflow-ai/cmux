import AppKit
import CmuxBrowser
import SwiftUI

extension BrowserDevToolsIconColorOption {
    /// The resolved SwiftUI tint for the browser panel's DevTools button.
    ///
    /// Stays app-side because the `.accent` case binds to the live app accent
    /// via `cmuxAccentColor()`, which is an app-target color. The persisted
    /// value type (``BrowserDevToolsIconColorOption``) lives in `CmuxBrowser`.
    var color: Color {
        switch self {
        case .bonsplitInactive:
            // Matches Bonsplit tab icon tint for inactive tabs.
            return Color(nsColor: .secondaryLabelColor)
        case .bonsplitActive:
            // Matches Bonsplit tab icon tint for active tabs.
            return Color(nsColor: .labelColor)
        case .accent:
            return cmuxAccentColor()
        case .tertiary:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }
}
