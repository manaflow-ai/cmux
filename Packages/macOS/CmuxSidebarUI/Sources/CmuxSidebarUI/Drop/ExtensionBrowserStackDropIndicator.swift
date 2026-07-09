public import SwiftUI

/// The thin accent line shown along the top or bottom edge of an extension
/// sidebar browser-stack tile or row while a drag would drop there.
///
/// Drained byte-identically from
/// `VerticalTabsSidebar.extensionBrowserStackDropIndicator` in the app target.
/// The owning view overlays one instance per edge; the bar renders only when the
/// active drag's ``SidebarDropIndicator`` matches this row's workspace id and the
/// given ``SidebarDropEdge``. The match is computed by the caller and passed in as
/// ``isActive`` so this package view holds no drag-state store reference
/// (snapshot-boundary rule). The accent color is injected (the app supplies its
/// `cmuxAccentColor()`).
public struct ExtensionBrowserStackDropIndicator: View {
    let isActive: Bool
    let accent: Color

    /// Creates the browser-stack drop indicator bar.
    /// - Parameters:
    ///   - isActive: Whether the active drag would drop on this row's edge, i.e.
    ///     the live ``SidebarDropIndicator`` equals the indicator for this row and
    ///     edge.
    ///   - accent: The accent color used to fill the indicator bar.
    public init(isActive: Bool, accent: Color) {
        self.isActive = isActive
        self.accent = accent
    }

    public var body: some View {
        if isActive {
            Rectangle()
                .fill(accent)
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
    }
}
