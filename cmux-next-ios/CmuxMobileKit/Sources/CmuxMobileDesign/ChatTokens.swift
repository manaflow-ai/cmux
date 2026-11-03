#if os(iOS)
import SwiftUI
import UIKit

/// SPEC 2.1 colors used by chat, Feed and the diff viewer, as dynamic light/dark pairs.
/// Prefixed `mobile` so they never collide with system names.
extension Color {
    static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static let cmuxMobileBackground = dynamic(dark: rgba(0x000000), light: rgba(0xFFFFFF))
    public static let cmuxMobileSurface = dynamic(dark: rgba(0x1C1C1E), light: rgba(0xFFFFFF))
    public static let cmuxMobileSurfaceRaised = dynamic(dark: rgba(0x2C2C2E), light: rgba(0xF2F2F7))
    /// Card background on `cmuxMobileBackground` (permission, question, plan cards): `surface` in dark, a light gray in light.
    public static let cmuxMobileCard = dynamic(dark: rgba(0x1C1C1E), light: rgba(0xF2F2F7))
    public static let cmuxMobileBubble = dynamic(dark: rgba(0x2C2C2E), light: rgba(0xEDEDED))
    public static let cmuxMobileCodeBackground = dynamic(dark: rgba(0x1C1C1E), light: rgba(0xF5F5F7))
    public static let cmuxMobileFill = dynamic(dark: rgba(0xFFFFFF, 0.08), light: rgba(0x000000, 0.05))
    public static let cmuxMobileFillSelected = dynamic(dark: rgba(0xFFFFFF, 0.16), light: rgba(0x000000, 0.09))
    public static let cmuxMobileFillPressed = dynamic(dark: rgba(0xFFFFFF, 0.22), light: rgba(0x000000, 0.13))
    /// The user's accent (Settings > Appearance > Accent color, `CmuxMobileAccentTheme`) as a
    /// concrete color (`Color.primary` turns vibrant gray inside glass). Read in a view's body,
    /// the view redraws when the choice changes. Never hard-code a hue in its place.
    public static var cmuxMobileAccent: Color { CmuxMobileAccentTheme.shared.accent.accent.color }
    public static var cmuxMobileOnAccent: Color { CmuxMobileAccentTheme.shared.accent.onAccent.color }
    public static let cmuxMobileSuccess = dynamic(dark: rgba(0x30D158), light: rgba(0x34C759))
    public static let cmuxMobileDanger = dynamic(dark: rgba(0xFF453A), light: rgba(0xFF3B30))
    public static let cmuxMobileWarning = dynamic(dark: rgba(0xFFD60A), light: rgba(0xFFCC00))
    public static let cmuxMobileDiffAddText = dynamic(dark: rgba(0x3FB950), light: rgba(0x1A7F37))
    public static let cmuxMobileDiffDelText = dynamic(dark: rgba(0xF85149), light: rgba(0xCF222E))
    public static let cmuxMobileDiffAddRow = dynamic(dark: rgba(0x2EA043, 0.15), light: rgba(0xDAFBE1))
    public static let cmuxMobileDiffDelRow = dynamic(dark: rgba(0xF85149, 0.15), light: rgba(0xFFEBE9))
    public static let cmuxMobileDiffAddGutter = dynamic(dark: rgba(0x2EA043, 0.30), light: rgba(0xCCFFD8))
    public static let cmuxMobileDiffDelGutter = dynamic(dark: rgba(0xF85149, 0.30), light: rgba(0xFFD7D5))
    public static let cmuxMobileDiffAddWord = dynamic(dark: rgba(0x2EA043, 0.40), light: rgba(0xACEEBB))
    public static let cmuxMobileDiffDelWord = dynamic(dark: rgba(0xF85149, 0.40), light: rgba(0xFFCECB))
    public static let cmuxMobileDiffHunk = dynamic(dark: rgba(0xFFFFFF, 0.04), light: rgba(0xDDF4FF, 0.5))
    /// Syntax palette (SPEC 2.1 fallback: Apple system colors pushed toward readable on `codeBg`).
    public static let cmuxMobileSyntaxKeyword = dynamic(dark: rgba(0xFF7AB2), light: rgba(0xAD3DA4))
    public static let cmuxMobileSyntaxString = dynamic(dark: rgba(0xFC6A5D), light: rgba(0xD12F1B))
    public static let cmuxMobileSyntaxNumber = dynamic(dark: rgba(0xD9C97C), light: rgba(0x272AD8))
    public static let cmuxMobileSyntaxType = dynamic(dark: rgba(0x5DD8FF), light: rgba(0x0B4F79))
    public static let cmuxMobileSyntaxFunction = dynamic(dark: rgba(0x67B7A4), light: rgba(0x326D74))
    public static let cmuxMobileSyntaxComment = dynamic(dark: rgba(0x7F8C98), light: rgba(0x707F8C))
}

/// The same SPEC 2.1 tokens as UIKit colors, for views drawn without SwiftUI (the Feed's rows).
extension UIColor {
    public static let cmuxMobileBackground = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x000000) : Color.rgba(0xFFFFFF) }
    public static let cmuxMobileSurface = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x1C1C1E) : Color.rgba(0xFFFFFF) }
    public static let cmuxMobileSurfaceRaised = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x2C2C2E) : Color.rgba(0xF2F2F7) }
    public static let cmuxMobileCard = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x1C1C1E) : Color.rgba(0xF2F2F7) }
    public static let cmuxMobileBubble = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x2C2C2E) : Color.rgba(0xEDEDED) }
    public static let cmuxMobileCodeBackground = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x1C1C1E) : Color.rgba(0xF5F5F7) }
    public static let cmuxMobileFill = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFFFFFF, 0.08) : Color.rgba(0x000000, 0.05) }
    public static let cmuxMobileFillSelected = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFFFFFF, 0.16) : Color.rgba(0x000000, 0.09) }
    public static let cmuxMobileFillPressed = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFFFFFF, 0.22) : Color.rgba(0x000000, 0.13) }
    /// The user's accent: resolved from the current choice each time a trait collection resolves it.
    public static let cmuxMobileAccent = UIColor { CmuxMobileAccentTheme.shared.accent.accent.uiColor.resolvedColor(with: $0) }
    public static let cmuxMobileOnAccent = UIColor { CmuxMobileAccentTheme.shared.accent.onAccent.uiColor.resolvedColor(with: $0) }
    public static let cmuxMobileSuccess = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x30D158) : Color.rgba(0x34C759) }
    public static let cmuxMobileDanger = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFF453A) : Color.rgba(0xFF3B30) }
    public static let cmuxMobileWarning = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFFD60A) : Color.rgba(0xFFCC00) }
    public static let cmuxMobileDiffAddText = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x3FB950) : Color.rgba(0x1A7F37) }
    public static let cmuxMobileDiffDelText = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xF85149) : Color.rgba(0xCF222E) }
    public static let cmuxMobileDiffAddRow = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x2EA043, 0.15) : Color.rgba(0xDAFBE1) }
    public static let cmuxMobileDiffDelRow = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xF85149, 0.15) : Color.rgba(0xFFEBE9) }
    public static let cmuxMobileDiffAddGutter = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x2EA043, 0.30) : Color.rgba(0xCCFFD8) }
    public static let cmuxMobileDiffDelGutter = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xF85149, 0.30) : Color.rgba(0xFFD7D5) }
    public static let cmuxMobileDiffAddWord = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x2EA043, 0.40) : Color.rgba(0xACEEBB) }
    public static let cmuxMobileDiffDelWord = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xF85149, 0.40) : Color.rgba(0xFFCECB) }
    public static let cmuxMobileDiffHunk = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFFFFFF, 0.04) : Color.rgba(0xDDF4FF, 0.5) }
    public static let cmuxMobileSyntaxKeyword = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFF7AB2) : Color.rgba(0xAD3DA4) }
    public static let cmuxMobileSyntaxString = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xFC6A5D) : Color.rgba(0xD12F1B) }
    public static let cmuxMobileSyntaxNumber = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0xD9C97C) : Color.rgba(0x272AD8) }
    public static let cmuxMobileSyntaxType = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x5DD8FF) : Color.rgba(0x0B4F79) }
    public static let cmuxMobileSyntaxFunction = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x67B7A4) : Color.rgba(0x326D74) }
    public static let cmuxMobileSyntaxComment = UIColor { $0.userInterfaceStyle == .dark ? Color.rgba(0x7F8C98) : Color.rgba(0x707F8C) }
}

/// SPEC 2.7 springs.
extension Animation {
    public static let cmuxMobileSnap = Animation.spring(duration: 0.25, bounce: 0)
    public static let cmuxMobileSmooth = Animation.spring(duration: 0.35, bounce: 0)
    public static let cmuxMobileSnappy = Animation.spring(duration: 0.35, bounce: 0.12)
    public static let cmuxMobileGentle = Animation.spring(duration: 0.5, bounce: 0)
}

/// SPEC 4.1 `IconAction`: a 32 pt hit target around a 17 pt `label2` symbol.
public struct IconAction: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    public init(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconActionLabel(systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The glyph of an `IconAction` (also the label of a `ShareLink` or `Menu`
/// in the same row): 16 pt in a 44 pt target at the default text size,
/// scaled with Dynamic Type like the text around it.
public struct IconActionLabel: View {
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16

    public init(_ systemImage: String) {
        self.systemImage = systemImage
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(.secondary)
            .contentTransition(.symbolEffect(.replace))
            // 44 pt hit target at least (HIG); the glyph keeps its 16 pt size.
            .frame(width: max(44, size * 2), height: max(44, size * 2))
            .contentShape(.rect)
    }
}

/// SPEC 4.1 `PrimaryCapsule` (accent fill) in inline (40) or large (48/52) size.
public struct CmuxMobileCapsuleButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, destructive }
    public enum Size: Sendable { case inline, compact, bar, large }

    var kind: Kind
    var size: Size
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind = .primary, size: Size = .inline) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = switch size {
        case .inline, .compact: 40
        case .bar: 48
        case .large: 52
        }
        configuration.label
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, size == .compact ? 12 : 20)
            // Bar buttons (permission options) may wrap to a second line.
            .padding(.vertical, size == .bar ? 6 : 0)
            .frame(minHeight: height, maxHeight: size == .bar ? nil : height)
            .frame(maxWidth: size == .inline ? nil : .infinity)
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.cmuxMobileSnap, value: configuration.isPressed)
            // 40 pt capsules keep a 44 pt hit target (HIG): 2 pt of invisible margin above and below.
            .padding(.vertical, height < 44 ? (44 - height) / 2 : 0)
            .contentShape(.rect)
    }

    private var foreground: Color {
        guard isEnabled else { return Color(uiColor: .tertiaryLabel) }
        return switch kind {
        case .primary: .cmuxMobileOnAccent
        case .secondary: .primary
        case .destructive: .cmuxMobileDanger
        }
    }

    private var background: Color {
        guard isEnabled else { return .cmuxMobileFill }
        return switch kind {
        case .primary: .cmuxMobileAccent
        case .secondary, .destructive: .cmuxMobileFillSelected
        }
    }
}
#endif
