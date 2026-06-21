public import SwiftUI
public import CmuxSidebarProviderKit

/// The leading glyph rendered for a row in an extension sidebar's browser-stack
/// column (the grid tiles and the loose/grouped list rows).
///
/// Drained byte-identically from `VerticalTabsSidebar.extensionBrowserStackIcon`
/// in the app target. The icon shape, foreground, and background are derived from
/// the provider-supplied ``CmuxSidebarProviderIcon`` (a `nil` icon falls back to a
/// circle with the default foreground and a faint primary background). A
/// `systemImageName` renders an SF Symbol; otherwise the icon's `text` (or `"."`)
/// is drawn. The hex colors resolve through ``Color/sidebarHexColor(_:fallback:)``
/// so the view holds no app-target appearance dependency.
public struct ExtensionBrowserStackIcon: View {
    let icon: CmuxSidebarProviderIcon?
    let size: CGFloat

    /// Creates the browser-stack icon glyph.
    /// - Parameters:
    ///   - icon: The provider-supplied icon descriptor, or `nil` for the default
    ///     circle glyph.
    ///   - size: The width and height of the icon, in points. The symbol/text
    ///     font and rounded-rectangle corner radius scale from this value.
    public init(icon: CmuxSidebarProviderIcon?, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        let shape = icon?.shape ?? .circle
        let foreground = Color.sidebarHexColor(icon?.foregroundColorHex, fallback: .primary)
        let background = Color.sidebarHexColor(icon?.backgroundColorHex, fallback: Color.primary.opacity(0.16))
        return ZStack {
            if shape == .circle {
                Circle().fill(background)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(background)
            }
            if let systemImageName = icon?.systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundColor(foreground)
            } else {
                Text(icon?.text ?? ".")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundColor(foreground)
            }
        }
        .frame(width: size, height: size)
    }
}
