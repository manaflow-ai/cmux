import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Fully resolved badge to draw on one terminal surface: the substituted text
/// plus its validated configuration. Value type so it can be diffed
/// (``Equatable``) cheaply before touching AppKit on the hot `updateNSView`
/// path. Absence of this value means "draw no badge".
struct TerminalBadgeContent: Equatable {
    var text: String
    var configuration: TerminalBadgeConfiguration
}

/// UserDefaults key strings and default values for the terminal badge,
/// forwarded from ``TerminalCatalogSection`` (the single source of truth) so the
/// `@AppStorage` readers stay in sync with the Settings panel. Mirrors the
/// existing `NotificationPaneRingSettings` / `TerminalScrollBarSettings`
/// settings-accessor enums.
enum TerminalBadgeSettings {
    static let enabledKey = TerminalCatalogSection().badgeEnabled.userDefaultsKey
    static let templateKey = TerminalCatalogSection().badgeTemplate.userDefaultsKey
    static let positionKey = TerminalCatalogSection().badgePosition.userDefaultsKey
    static let opacityKey = TerminalCatalogSection().badgeOpacity.userDefaultsKey
    static let fontSizeKey = TerminalCatalogSection().badgeFontSize.userDefaultsKey
    static let colorHexKey = TerminalCatalogSection().badgeColorHex.userDefaultsKey

    static let defaultEnabled = TerminalCatalogSection().badgeEnabled.defaultValue
    static let defaultTemplate = TerminalCatalogSection().badgeTemplate.defaultValue
    static let defaultPosition = TerminalCatalogSection().badgePosition.defaultValue
    static let defaultOpacity = TerminalCatalogSection().badgeOpacity.defaultValue
    static let defaultFontSize = TerminalCatalogSection().badgeFontSize.defaultValue
    static let defaultColorHex = TerminalCatalogSection().badgeColorHex.defaultValue
}

extension TerminalBadgePosition {
    /// SwiftUI alignment for anchoring the badge inside the surface rect.
    var swiftUIAlignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// Whether the badge hugs the trailing edge (drives multi-line text
    /// alignment so wrapped lines stay flush with the anchored corner).
    var isTrailing: Bool {
        switch self {
        case .topTrailing, .bottomTrailing: return true
        case .topLeading, .bottomLeading: return false
        }
    }
}

/// SwiftUI overlay rendering the badge text anchored to a surface corner. The
/// view is non-interactive; pointer handling is additionally disabled at the
/// hosting-view layer so it can never block terminal selection or clicks.
struct TerminalBadgeOverlayView: View {
    let content: TerminalBadgeContent

    var body: some View {
        let configuration = content.configuration
        let color = Color(nsColor: NSColor(hex: configuration.colorHex) ?? .white)
        Text(content.text)
            .font(.system(size: configuration.fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .opacity(configuration.opacity)
            .lineLimit(2)
            .multilineTextAlignment(configuration.position.isTrailing ? .trailing : .leading)
            .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: configuration.position.swiftUIAlignment
            )
            .padding(14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `NSHostingView` for the badge overlay that is transparent to the pointer:
/// `hitTest` always returns `nil` so every event falls through to the terminal
/// surface beneath the watermark.
final class TerminalBadgeOverlayHostingView: NSHostingView<TerminalBadgeOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
