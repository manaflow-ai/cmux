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

/// Bridges the ``TerminalCatalogSection`` badge keys into the macOS app:
/// exposes the UserDefaults key strings (for `@AppStorage`) and default values,
/// and resolves the current settings into a ``TerminalBadgeContent``.
///
/// The catalog is the single source of truth for the key strings and defaults;
/// these accessors forward to it so the runtime reader and the Settings UI can
/// never drift apart.
enum TerminalBadgeSettings {
    private static let terminal = TerminalCatalogSection()

    static let enabledKey = terminal.badgeEnabled.userDefaultsKey
    static let templateKey = terminal.badgeTemplate.userDefaultsKey
    static let positionKey = terminal.badgePosition.userDefaultsKey
    static let opacityKey = terminal.badgeOpacity.userDefaultsKey
    static let fontSizeKey = terminal.badgeFontSize.userDefaultsKey
    static let colorHexKey = terminal.badgeColorHex.userDefaultsKey

    static let defaultEnabled = terminal.badgeEnabled.defaultValue
    static let defaultTemplate = terminal.badgeTemplate.defaultValue
    static let defaultPosition = terminal.badgePosition.defaultValue
    static let defaultOpacity = terminal.badgeOpacity.defaultValue
    static let defaultFontSize = terminal.badgeFontSize.defaultValue
    static let defaultColorHex = terminal.badgeColorHex.defaultValue

    /// Builds the badge to render for one surface, or `nil` when the badge is
    /// disabled or the resolved text is empty.
    static func content(
        enabled: Bool,
        template: String,
        workspace: String,
        tab: String,
        position: TerminalBadgePosition,
        opacity: Double,
        fontSize: Double,
        colorHex: String
    ) -> TerminalBadgeContent? {
        guard enabled else { return nil }
        let configuration = TerminalBadgeConfiguration(
            template: template,
            position: position,
            opacity: opacity,
            fontSize: fontSize,
            colorHex: colorHex
        )
        let text = configuration.resolvedText(workspace: workspace, tab: tab)
        guard !text.isEmpty else { return nil }
        return TerminalBadgeContent(text: text, configuration: configuration)
    }
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
