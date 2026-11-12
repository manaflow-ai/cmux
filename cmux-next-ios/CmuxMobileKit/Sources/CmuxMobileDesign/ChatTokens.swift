#if os(iOS)
import SwiftUI
import UIKit

/// SPEC 2.1 colors used by chat, Feed and the diff viewer: the current
/// appearance's palette roles (``CmuxMobileColorRole``), dynamic per light/dark
/// and per theme. Prefixed `mobile` so they never collide with system names.
extension CmuxMobileColorRole {
    /// A `UIColor` that resolves this role in the current appearance at each
    /// trait resolution (a theme change re-resolves it: ``CmuxMobileAppearanceRevisionTrait``).
    public var uiColor: UIColor {
        let role = self
        return UIColor { traits in
            CmuxMobileAppearance.shared.token(role)
                .value(dark: traits.userInterfaceStyle == .dark, highContrast: traits.accessibilityContrast == .high).uiColor
        }
    }
}

extension Color {
    public static var cmuxMobileBackground: Color { CmuxMobileAppearance.shared.token(.bg).reading(.bg).color }
    public static var cmuxMobileSurface: Color { CmuxMobileAppearance.shared.token(.surface).reading(.surface).color }
    public static var cmuxMobileSurfaceRaised: Color { CmuxMobileAppearance.shared.token(.surfaceRaised).reading(.surfaceRaised).color }
    /// Card background on `cmuxMobileBackground` (permission, question, plan cards): `surface` in dark, a light gray in light.
    public static var cmuxMobileCard: Color { CmuxMobileAppearance.shared.token(.card).reading(.card).color }
    public static var cmuxMobileBubble: Color { CmuxMobileAppearance.shared.token(.bubble).reading(.bubble).color }
    public static var cmuxMobileCodeBackground: Color { CmuxMobileAppearance.shared.token(.codeBg).reading(.codeBg).color }
    public static var cmuxMobileFill: Color { CmuxMobileAppearance.shared.token(.fill).reading(.fill).color }
    public static var cmuxMobileFillSelected: Color { CmuxMobileAppearance.shared.token(.fillSelected).reading(.fillSelected).color }
    public static var cmuxMobileFillPressed: Color { CmuxMobileAppearance.shared.token(.fillPressed).reading(.fillPressed).color }
    /// The user's accent (Settings > Appearance > Accent color, `CmuxMobileAccentTheme`) as a
    /// concrete color (`Color.primary` turns vibrant gray inside glass). Read in a view's body,
    /// the view redraws when the choice changes. Never hard-code a hue in its place.
    public static var cmuxMobileAccent: Color { CmuxMobileAppearance.shared.token(.accent).reading(.accent).color }
    public static var cmuxMobileOnAccent: Color { CmuxMobileAppearance.shared.token(.onAccent).reading(.onAccent).color }
    public static var cmuxMobileSuccess: Color { CmuxMobileAppearance.shared.token(.success).reading(.success).color }
    public static var cmuxMobileDanger: Color { CmuxMobileAppearance.shared.token(.danger).reading(.danger).color }
    public static var cmuxMobileWarning: Color { CmuxMobileAppearance.shared.token(.warning).reading(.warning).color }
    public static var cmuxMobileDiffAddText: Color { CmuxMobileAppearance.shared.token(.diffAddText).reading(.diffAddText).color }
    public static var cmuxMobileDiffDelText: Color { CmuxMobileAppearance.shared.token(.diffDelText).reading(.diffDelText).color }
    public static var cmuxMobileDiffAddRow: Color { CmuxMobileAppearance.shared.token(.diffAddRow).reading(.diffAddRow).color }
    public static var cmuxMobileDiffDelRow: Color { CmuxMobileAppearance.shared.token(.diffDelRow).reading(.diffDelRow).color }
    public static var cmuxMobileDiffAddGutter: Color { CmuxMobileAppearance.shared.token(.diffAddGutter).reading(.diffAddGutter).color }
    public static var cmuxMobileDiffDelGutter: Color { CmuxMobileAppearance.shared.token(.diffDelGutter).reading(.diffDelGutter).color }
    public static var cmuxMobileDiffAddWord: Color { CmuxMobileAppearance.shared.token(.diffAddWord).reading(.diffAddWord).color }
    public static var cmuxMobileDiffDelWord: Color { CmuxMobileAppearance.shared.token(.diffDelWord).reading(.diffDelWord).color }
    public static var cmuxMobileDiffHunk: Color { CmuxMobileAppearance.shared.token(.diffHunkBg).reading(.diffHunkBg).color }
    /// Syntax palette (SPEC 2.1 fallback: Apple system colors pushed toward readable on `codeBg`).
    public static var cmuxMobileSyntaxKeyword: Color { CmuxMobileAppearance.shared.token(.syntaxKeyword).reading(.syntaxKeyword).color }
    public static var cmuxMobileSyntaxString: Color { CmuxMobileAppearance.shared.token(.syntaxString).reading(.syntaxString).color }
    public static var cmuxMobileSyntaxNumber: Color { CmuxMobileAppearance.shared.token(.syntaxNumber).reading(.syntaxNumber).color }
    public static var cmuxMobileSyntaxType: Color { CmuxMobileAppearance.shared.token(.syntaxType).reading(.syntaxType).color }
    public static var cmuxMobileSyntaxFunction: Color { CmuxMobileAppearance.shared.token(.syntaxFunction).reading(.syntaxFunction).color }
    public static var cmuxMobileSyntaxComment: Color { CmuxMobileAppearance.shared.token(.syntaxComment).reading(.syntaxComment).color }
}

/// The same SPEC 2.1 tokens as UIKit colors, for views drawn without SwiftUI (the Feed's rows):
/// each resolves its role in the current appearance whenever UIKit resolves it.
extension UIColor {
    public static let cmuxMobileBackground = CmuxMobileColorRole.bg.uiColor
    public static let cmuxMobileSurface = CmuxMobileColorRole.surface.uiColor
    public static let cmuxMobileSurfaceRaised = CmuxMobileColorRole.surfaceRaised.uiColor
    public static let cmuxMobileCard = CmuxMobileColorRole.card.uiColor
    public static let cmuxMobileBubble = CmuxMobileColorRole.bubble.uiColor
    public static let cmuxMobileCodeBackground = CmuxMobileColorRole.codeBg.uiColor
    public static let cmuxMobileFill = CmuxMobileColorRole.fill.uiColor
    public static let cmuxMobileFillSelected = CmuxMobileColorRole.fillSelected.uiColor
    public static let cmuxMobileFillPressed = CmuxMobileColorRole.fillPressed.uiColor
    /// The user's accent: resolved from the current choice each time a trait collection resolves it.
    public static let cmuxMobileAccent = CmuxMobileColorRole.accent.uiColor
    public static let cmuxMobileOnAccent = CmuxMobileColorRole.onAccent.uiColor
    public static let cmuxMobileSuccess = CmuxMobileColorRole.success.uiColor
    public static let cmuxMobileDanger = CmuxMobileColorRole.danger.uiColor
    public static let cmuxMobileWarning = CmuxMobileColorRole.warning.uiColor
    public static let cmuxMobileDiffAddText = CmuxMobileColorRole.diffAddText.uiColor
    public static let cmuxMobileDiffDelText = CmuxMobileColorRole.diffDelText.uiColor
    public static let cmuxMobileDiffAddRow = CmuxMobileColorRole.diffAddRow.uiColor
    public static let cmuxMobileDiffDelRow = CmuxMobileColorRole.diffDelRow.uiColor
    public static let cmuxMobileDiffAddGutter = CmuxMobileColorRole.diffAddGutter.uiColor
    public static let cmuxMobileDiffDelGutter = CmuxMobileColorRole.diffDelGutter.uiColor
    public static let cmuxMobileDiffAddWord = CmuxMobileColorRole.diffAddWord.uiColor
    public static let cmuxMobileDiffDelWord = CmuxMobileColorRole.diffDelWord.uiColor
    public static let cmuxMobileDiffHunk = CmuxMobileColorRole.diffHunkBg.uiColor
    public static let cmuxMobileSyntaxKeyword = CmuxMobileColorRole.syntaxKeyword.uiColor
    public static let cmuxMobileSyntaxString = CmuxMobileColorRole.syntaxString.uiColor
    public static let cmuxMobileSyntaxNumber = CmuxMobileColorRole.syntaxNumber.uiColor
    public static let cmuxMobileSyntaxType = CmuxMobileColorRole.syntaxType.uiColor
    public static let cmuxMobileSyntaxFunction = CmuxMobileColorRole.syntaxFunction.uiColor
    public static let cmuxMobileSyntaxComment = CmuxMobileColorRole.syntaxComment.uiColor
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            // Bar buttons (permission options) may wrap to a second line; at
            // accessibility text sizes every capsule grows with its title instead of clipping it.
            .padding(.vertical, size == .bar || dynamicTypeSize.isAccessibilitySize ? 6 : 0)
            .frame(minHeight: height, maxHeight: size == .bar || dynamicTypeSize.isAccessibilitySize ? nil : height)
            .frame(maxWidth: size == .inline ? nil : .infinity)
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.cmuxMobileSnap.unlessReduceMotion, value: configuration.isPressed)
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
