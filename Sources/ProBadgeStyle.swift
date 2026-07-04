import AppKit
import Foundation
import Observation
import SwiftUI

/// Visual variants for the Pro upgrade badge shown in the sidebar footer and
/// the titlebar trailing controls. DEBUG exploration: the active variant is
/// switched from Debug > Debug Windows > Pro Badge Style… and persisted in
/// UserDefaults so every surface stays in sync live. One variant ships; the
/// rest get deleted once picked.
enum ProBadgeStyle: String, CaseIterable, Identifiable {
    case textPro
    case textGetPro
    case textUpgrade
    case accentPro
    case gradientProSolid
    case crownPro
    case crownOnly
    case crownAccent
    case sparklesPro
    case boltPro
    case iphonePro
    case emojiCrownPro
    case emojiSparklesPro
    case emojiGemPro
    case emojiRocketPro

    var id: String { rawValue }

    enum Leading {
        case none
        case symbol(String)
        case emoji(String)
    }

    var leading: Leading {
        switch self {
        case .textPro, .textGetPro, .textUpgrade, .accentPro, .gradientProSolid:
            return .none
        case .crownPro, .crownOnly, .crownAccent:
            return .symbol("crown")
        case .sparklesPro:
            return .symbol("sparkles")
        case .boltPro:
            return .symbol("bolt.fill")
        case .iphonePro:
            return .symbol("iphone")
        case .emojiCrownPro:
            return .emoji("👑")
        case .emojiSparklesPro:
            return .emoji("✨")
        case .emojiGemPro:
            return .emoji("💎")
        case .emojiRocketPro:
            return .emoji("🚀")
        }
    }

    var text: String? {
        switch self {
        case .crownOnly:
            return nil
        case .textPro, .textUpgrade:
            return String(localized: "sidebar.pro.badge", defaultValue: "Upgrade")
        case .textGetPro:
            return "Get Pro"
        default:
            return "Pro"
        }
    }

    /// How the badge is tinted: plain secondary-label chrome, the cmux logo
    /// gradient as a soft tint, or the gradient as a solid fill.
    enum Appearance {
        case plain
        case gradientTint
        case gradientSolid
    }

    var appearance: Appearance {
        switch self {
        case .accentPro, .crownAccent:
            return .gradientTint
        case .gradientProSolid:
            return .gradientSolid
        default:
            return .plain
        }
    }

    /// Debug-window label (developer-facing, not localized).
    var displayName: String {
        switch self {
        case .textPro: return "Text: Pro"
        case .textGetPro: return "Text: Get Pro"
        case .textUpgrade: return "Text: Upgrade"
        case .accentPro: return "Gradient: Pro (tint)"
        case .gradientProSolid: return "Gradient: Pro (solid)"
        case .crownPro: return "Crown + Pro"
        case .crownOnly: return "Crown only"
        case .crownAccent: return "Crown + Pro (gradient)"
        case .sparklesPro: return "Sparkles + Pro"
        case .boltPro: return "Bolt + Pro"
        case .iphonePro: return "iPhone + Pro"
        case .emojiCrownPro: return "👑 Pro"
        case .emojiSparklesPro: return "✨ Pro"
        case .emojiGemPro: return "💎 Pro"
        case .emojiRocketPro: return "🚀 Pro"
        }
    }
}

/// UserDefaults-backed selection shared by every badge surface and the
/// debug window.
@MainActor
@Observable
final class ProBadgeStyleStore {
    static let shared = ProBadgeStyleStore()

    private static let defaultsKey = "debug.proBadgeStyle"
    private static let dismissedKey = "proBadge.dismissed"

    var current: ProBadgeStyle {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
        }
    }

    /// Users can permanently hide the badge via its hover X; persisted so it
    /// stays hidden across launches. The Settings Account card remains the
    /// durable upgrade entrypoint.
    var isDismissed: Bool {
        didSet {
            UserDefaults.standard.set(isDismissed, forKey: Self.dismissedKey)
        }
    }

    private init() {
        current = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(ProBadgeStyle.init(rawValue:)) ?? .textPro
        isDismissed = UserDefaults.standard.bool(forKey: Self.dismissedKey)
    }
}

/// A narrow slice of the cmux logo chevron gradient
/// (web/public/cmux-icon.svg: #12c7f5 -> #2d8cff@0.52 -> #6c5cff). The
/// icon spreads that ramp across the whole chevron, so any local patch
/// only shifts hue slightly; the badge samples t=0.35...0.75 of the ramp
/// (#249FFC -> #4B75FF) to match that local subtlety instead of showing
/// the full cyan->violet sweep in 40pt.
enum ProBadgePalette {
    static let logoGradient = LinearGradient(
        colors: [
            Color(red: 0x24 / 255, green: 0x9F / 255, blue: 0xFC / 255),
            Color(red: 0x4B / 255, green: 0x75 / 255, blue: 0xFF / 255),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static func foreground(for style: ProBadgeStyle) -> AnyShapeStyle {
        switch style.appearance {
        case .plain:
            return AnyShapeStyle(Color(nsColor: .secondaryLabelColor))
        case .gradientTint:
            return AnyShapeStyle(logoGradient)
        case .gradientSolid:
            return AnyShapeStyle(Color.white)
        }
    }

    static func fill(for style: ProBadgeStyle, isHovered: Bool) -> AnyShapeStyle {
        switch style.appearance {
        case .plain:
            return AnyShapeStyle(isHovered ? Color(nsColor: .quaternaryLabelColor) : .clear)
        case .gradientTint:
            return AnyShapeStyle(logoGradient.opacity(isHovered ? 0.32 : 0.18))
        case .gradientSolid:
            return AnyShapeStyle(logoGradient.opacity(isHovered ? 0.85 : 1))
        }
    }
}

/// Icon + text content of one badge style, tinted per appearance. No capsule.
struct ProBadgeContent: View {
    let style: ProBadgeStyle

    var body: some View {
        let foreground = ProBadgePalette.foreground(for: style)
        HStack(spacing: 3) {
            switch style.leading {
            case .none:
                EmptyView()
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: 9))
            }
            if let text = style.text {
                Text(text)
                    .cmuxFont(size: 10, weight: .semibold)
                    .foregroundStyle(foreground)
            }
        }
    }
}

/// Capsule background matching a style's appearance (border for plain,
/// gradient fill otherwise).
private struct ProBadgeCapsule: ViewModifier {
    let style: ProBadgeStyle
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(
                Capsule()
                    .strokeBorder(
                        style.appearance == .plain ? Color(nsColor: .separatorColor) : Color.clear,
                        lineWidth: style.appearance == .plain ? 1 : 0
                    )
                    .background(Capsule().fill(ProBadgePalette.fill(for: style, isHovered: isHovered)))
            )
    }
}

/// Static capsule rendering for one badge style, used by the debug window's
/// preview rows.
struct ProBadgeLabel: View {
    let style: ProBadgeStyle
    var isHovered = false

    var body: some View {
        ProBadgeContent(style: style)
            .modifier(ProBadgeCapsule(style: style, isHovered: isHovered))
    }
}

/// The Pro badge: renders the active ``ProBadgeStyle`` and opens the shared
/// pricing destination. On hover the capsule widens to reveal a dismiss X
/// inside it. Gated on the pro-upgrade-ui feature flag.
struct ProBadgeView: View {
    @State private var isHovered = false

    private var helpTitle: String {
        String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…")
    }

    private var dismissTitle: String {
        String(localized: "sidebar.pro.badge.dismiss", defaultValue: "Hide the Pro badge")
    }

    var body: some View {
        if CmuxFeatureFlags.shared.isProUpgradeUIEnabled,
           !ProBadgeStyleStore.shared.isDismissed {
            let style = ProBadgeStyleStore.shared.current
            let foreground = ProBadgePalette.foreground(for: style)
            HStack(spacing: 0) {
                Button {
                    ProUpgradePresenter.present()
                } label: {
                    ProBadgeContent(style: style)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(helpTitle)
                .accessibilityLabel(helpTitle)
                .accessibilityIdentifier("ProBadgeButton")

                // The X is always laid out; only its container width animates,
                // so it's revealed by the widening capsule (clipped) rather
                // than fading or sliding on its own.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        ProBadgeStyleStore.shared.isDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(foreground)
                        .opacity(0.75)
                        .padding(.leading, 4)
                        .frame(width: isHovered ? 14 : 0, alignment: .leading)
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isHovered)
                .safeHelp(dismissTitle)
                .accessibilityLabel(dismissTitle)
                .accessibilityIdentifier("ProBadgeDismissButton")
            }
            .modifier(ProBadgeCapsule(style: style, isHovered: isHovered))
            .frame(height: 22, alignment: .center)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
    }
}

/// Debug window listing every badge variant with a live preview; clicking a
/// row applies it to the sidebar footer and titlebar immediately.
final class ProBadgeDebugWindowController: ReleasingWindowController {
    static let shared = ProBadgeDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Pro Badge Style"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.proBadgeDebug")
        window.center()
        window.contentView = NSHostingView(rootView: ProBadgeDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private struct ProBadgeDebugView: View {
    var body: some View {
        let current = ProBadgeStyleStore.shared.current
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Applies live to the sidebar footer and titlebar badge.")
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 6)
                if ProBadgeStyleStore.shared.isDismissed {
                    Button("Badge is dismissed — show it again") {
                        ProBadgeStyleStore.shared.isDismissed = false
                    }
                    .padding(.bottom, 6)
                }
                ForEach(ProBadgeStyle.allCases) { style in
                    Button {
                        ProBadgeStyleStore.shared.current = style
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: current == style ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(current == style ? Color.accentColor : Color.secondary)
                            ProBadgeLabel(style: style)
                            Text(style.displayName)
                                .cmuxFont(size: 12)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(current == style ? Color(nsColor: .quaternaryLabelColor) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
