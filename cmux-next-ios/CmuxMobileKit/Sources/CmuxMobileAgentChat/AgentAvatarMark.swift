#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import SwiftUI
import UIKit

/// An agent's round avatar, the one rule every surface draws it by (the Feed's rows, the hand-off
/// pages): the agent's own mark (design/agent-icons, as the Mac's sidebar and agent pane draw it)
/// in its owner's colors, centered in a circle softly tinted with the mark's color. A harness with
/// no mark (a terminal, an unknown agent) keeps its SF Symbol on the raised gray circle.
///
/// The marks are painted in the `.brand` style, so each owner's color rules hold (the Codex mark
/// is black or white only, and so is its circle's tint).
///
/// Where the agent runs sets the outline (`AgentAvatarHost`): a GUI agent chat (the native chat pane)
/// sits in a circle, a terminal agent (Claude Code, Codex in a terminal tab) in a continuous rounded
/// square, so the same mark tells the two apart with no extra part on it (Leo 2026-11-24, "a small
/// subscript symbol? but wouldn't that look kinda dingleberry-esque?"; the variants it was picked
/// from: `AgentAvatarHostGallery`).
public enum AgentAvatarMark {
    /// A terminal avatar's corner radius as a share of its side (the continuous curve of an app icon).
    public static let tileCornerShare = AgentBrandCatalog.terminalTileCornerShare

    /// `experiments.terminalAgentMark` (off by default, as on the Mac): whether a terminal agent's avatar takes the rounded
    /// square. Off, every avatar keeps its circle; the gallery (`AgentAvatarHostGallery`) passes its host directly.
    public static var terminalShapeEnabled: Bool { UserDefaults.standard.bool(forKey: "experiments.terminalAgentMark") }

    /// The corner radius of an avatar `side` points across: a circle's for a chat, a tile's for a terminal.
    public static func cornerRadius(side: CGFloat, host: AgentAvatarHost) -> CGFloat {
        host == .terminal ? side * tileCornerShare : side / 2
    }

    /// The mark's side as a share of the circle's diameter.
    public static let markShare: CGFloat = 0.5
    /// A fallback symbol's point size as a share of the circle's diameter.
    public static let symbolShare: CGFloat = 0.42

    /// The mark a harness draws in a circle `side` points across, or nil when it has none.
    /// A profile id draws its family's mark (`claude-sr2` → Claude), as `AgentSenderIcon`.
    public static func spec(harness: String, side: CGFloat) -> AgentBrandSpec? {
        AgentBrandCatalog.spec(forAgent: AgentSenderIcon.family(harness), pointSize: Double(side * markShare))
    }

    /// The SF Symbol of a harness with no mark.
    public static func fallbackSymbol(_ harness: String) -> String {
        switch harness {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow.rays"
        case "gemini": "sparkles"
        case "opencode": "curlybraces"
        case "terminal": "terminal"
        default: "sparkle"
        }
    }

    /// The circle's tint behind a mark: the mark's color (its tile's, when it sits on one), packed
    /// 0xRRGGBB, and how much of it shows over the page.
    public static func fill(_ spec: AgentBrandSpec, dark: Bool) -> (rgb: UInt32, opacity: Double) {
        ((spec.tile?.tone ?? spec.tone).rgb(dark: dark), dark ? 0.22 : 0.12)
    }

    /// What a UIKit row needs to draw one avatar: the circle's fill (it follows light and dark by
    /// itself) and the glyph for each appearance.
    public struct Rendered {
        public let fill: UIColor
        public let light: UIImage?
        public let dark: UIImage?
        /// False for a fallback symbol: a template image, tinted by its image view.
        public let isMark: Bool

        public func glyph(dark isDark: Bool) -> UIImage? { isDark ? dark : light }
    }

    /// The avatar of `harness` in a circle `side` points across. Drawn once per harness, size
    /// and screen scale, then shared: a row that configures only reads the cache.
    @MainActor public static func rendered(harness: String, side: CGFloat, scale: CGFloat) -> Rendered {
        let key = RenderKey(harness: harness, side: side, scale: scale)
        if let hit = cache[key] { return hit }
        let made = render(harness: harness, side: side, scale: scale)
        // Harness ids are a handful; a Mac that sends arbitrary ones cannot grow the cache.
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = made
        return made
    }

    private struct RenderKey: Hashable {
        let harness: String
        let side: CGFloat
        let scale: CGFloat
    }

    @MainActor private static var cache: [RenderKey: Rendered] = [:]

    @MainActor private static func render(harness: String, side: CGFloat, scale: CGFloat) -> Rendered {
        guard let spec = Self.spec(harness: harness, side: side) else {
            let symbol = UIImage(systemName: fallbackSymbol(harness),
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: side * symbolShare, weight: .medium))
            return Rendered(fill: .cmuxMobileSurfaceRaised, light: symbol, dark: symbol, isMark: false)
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale > 0 ? scale : 3
        format.opaque = false
        let markSide = (side * markShare).rounded()
        let rect = CGRect(x: 0, y: 0, width: markSide, height: markSide)
        func image(dark: Bool) -> UIImage {
            UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
                AgentBrandRenderer.draw(spec, in: context.cgContext, rect: rect, style: .brand, dark: dark,
                                        monoColor: CGColor(gray: 0, alpha: 1))
            }.withRenderingMode(.alwaysOriginal)
        }
        let fill = UIColor { traits in
            let tint = Self.fill(spec, dark: traits.userInterfaceStyle == .dark)
            return UIColor(red: CGFloat((tint.rgb >> 16) & 0xFF) / 255, green: CGFloat((tint.rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(tint.rgb & 0xFF) / 255, alpha: tint.opacity)
        }
        return Rendered(fill: fill, light: image(dark: false), dark: image(dark: true), isMark: true)
    }
}

/// The round avatar in SwiftUI, by `AgentAvatarMark`'s rule.
public struct AgentAvatar: View {
    private let harness: String
    private let side: CGFloat
    private let host: AgentAvatarHost
    @Environment(\.colorScheme) private var colorScheme

    public init(harness: String, side: CGFloat = 32, host: AgentAvatarHost = .chat) {
        self.harness = harness
        self.side = side
        self.host = host
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AgentAvatarMark.cornerRadius(side: side, host: host), style: .continuous)
    }

    public var body: some View {
        Group {
            if let spec = AgentAvatarMark.spec(harness: harness, side: side) {
                let tint = AgentAvatarMark.fill(spec, dark: colorScheme == .dark)
                AgentBrandMark(agent: AgentSenderIcon.family(harness), size: (side * AgentAvatarMark.markShare).rounded(), style: .brand)
                    .frame(width: side, height: side)
                    .background(Color(red: Double((tint.rgb >> 16) & 0xFF) / 255, green: Double((tint.rgb >> 8) & 0xFF) / 255,
                                      blue: Double(tint.rgb & 0xFF) / 255).opacity(tint.opacity), in: shape)
            } else {
                Image(systemName: AgentAvatarMark.fallbackSymbol(harness))
                    .font(.system(size: side * AgentAvatarMark.symbolShare, weight: .medium))
                    .frame(width: side, height: side)
                    .background(Color.cmuxMobileSurfaceRaised, in: shape)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Where an agent runs, which sets its avatar's outline (`AgentAvatarMark`): `chat`, the native agent
/// chat pane (a circle); `terminal`, a CLI agent in a terminal tab (a rounded square).
public enum AgentAvatarHost: Hashable, Sendable {
    case chat
    case terminal
}
#endif
