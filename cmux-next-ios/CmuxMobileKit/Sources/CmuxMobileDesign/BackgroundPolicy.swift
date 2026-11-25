#if os(iOS)
import SwiftUI
import UIKit

/// Which ground each screen draws (prototype, Settings > Appearance > Backgrounds): one policy for
/// Home, Workspaces, Feed, Settings, pushed pages, sheets and chats, so the tabs stop disagreeing
/// (Home on the Mac's painting, Feed on a fixed black, Settings on the theme's grey).
///
/// - ``current``: what shipped before the policy: each screen keeps its own ground.
/// - ``canvas``: the Mac's wallpaper behind everything (tabs, pages, sheets, chats), under a
///   heavier tint on reading surfaces. Without a wallpaper: the theme ground everywhere.
/// - ``layered``: the wallpaper only on the four tab roots (and the sidebar); everything you
///   push or present sits on the solid theme ground.
/// - ``flat``: no wallpaper anywhere; one solid theme ground (the Mac's color with Match Mac
///   theme on, else black or white) on every screen.
///
/// `-cmux-mobile-bg-policy NAME` (DEBUG) picks one for the launch, for screenshots.
public enum CmuxMobileBackgroundPolicy: String, CaseIterable, Identifiable, Sendable {
    case current, canvas, layered, flat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .current: "Current"
        case .canvas: "Wallpaper everywhere"
        case .layered: "Wallpaper on tabs"
        case .flat: "Solid everywhere"
        }
    }

    public var summary: String {
        switch self {
        case .current: "Each screen keeps its own ground, as before."
        case .canvas: "The Mac's wallpaper behind every screen, sheet and chat."
        case .layered: "The wallpaper on the four tabs; pages, sheets and chats are solid."
        case .flat: "No wallpaper; one solid theme color on every screen."
        }
    }

    /// What a screen at `level` draws under this policy.
    public func ground(_ level: CmuxMobileGroundLevel) -> CmuxMobileGroundKind {
        switch self {
        case .current: .legacy
        case .canvas: .wallpaper(minTint: level == .root ? 0 : 0.78)
        case .layered: level == .root ? .wallpaper(minTint: 0) : .solid
        case .flat: .solid
        }
    }
}

/// What a screen draws under a policy.
public enum CmuxMobileGroundKind: Equatable, Sendable {
    /// What the screen drew before the policy.
    case legacy
    /// The Mac's wallpaper under at least `minTint` of the ground; the solid ground without one.
    case wallpaper(minTint: Double)
    case solid
}

/// Where a screen sits: a tab's root (and the sidebar), a pushed page, a presented sheet, a chat.
public enum CmuxMobileGroundLevel: Sendable, Hashable {
    case root, page, sheet, chat
}

/// The chosen ``CmuxMobileBackgroundPolicy``, observed: SwiftUI grounds redraw when it changes;
/// UIKit lists read it when they configure (a relaunch applies it everywhere).
@Observable
public final class CmuxMobileBackgroundSetting: @unchecked Sendable {
    public static let shared = CmuxMobileBackgroundSetting()
    public static let settingKey = "cmuxMobile.settings.backgroundPolicy"
    @ObservationIgnored private let defaults: UserDefaults

    public var policy: CmuxMobileBackgroundPolicy {
        didSet { defaults.set(policy.rawValue, forKey: Self.settingKey) }
    }

    public init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        var launch: CmuxMobileBackgroundPolicy?
        #if DEBUG
        if let index = arguments.firstIndex(of: "-cmux-mobile-bg-policy"), index + 1 < arguments.count {
            launch = CmuxMobileBackgroundPolicy(rawValue: arguments[index + 1])
        }
        #endif
        policy = launch ?? defaults.string(forKey: Self.settingKey).flatMap(CmuxMobileBackgroundPolicy.init(rawValue:)) ?? .current
    }
}

/// A screen's ground under the chosen policy. `legacy` is what the screen drew before the policy
/// (kept under ``CmuxMobileBackgroundPolicy/current``); `grouped` picks the grouped solid (Settings).
public struct CmuxMobileGround<Legacy: View>: View {
    private let level: CmuxMobileGroundLevel
    private let grouped: Bool
    private let legacy: Legacy
    private let setting: CmuxMobileBackgroundSetting
    private let macTheme: CmuxMobileMacTheme

    public init(_ level: CmuxMobileGroundLevel, grouped: Bool = false, setting: CmuxMobileBackgroundSetting = .shared,
                macTheme: CmuxMobileMacTheme = .shared, @ViewBuilder legacy: () -> Legacy) {
        self.level = level
        self.grouped = grouped
        self.legacy = legacy()
        self.setting = setting
        self.macTheme = macTheme
    }

    public var body: some View {
        // A chat that follows the Mac's chat look draws in that look's light or dark style, so its
        // ground is the look's own color, never the phone's light or dark one (white text on a white
        // ground otherwise, under a light phone and a dark Mac theme).
        if level == .chat, let look = macTheme.chatLook, setting.policy != .current {
            chatGround(look)
        } else {
            policyGround
        }
    }

    @ViewBuilder private func chatGround(_ look: CmuxMobileChatLook) -> some View {
        let ground = Color(uiColor: CmuxMobileRGBA(red: look.background.red, green: look.background.green,
                                                     blue: look.background.blue).uiColor)
        switch setting.policy.ground(level) {
        case .wallpaper(let minTint):
            if let wallpaper = macTheme.wallpaper {
                GeometryReader { proxy in
                    Image(uiImage: wallpaper.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(ground.opacity(max(wallpaper.tint, minTint)))
                }
                .accessibilityHidden(true)
            } else {
                ground
            }
        default:
            ground
        }
    }

    @ViewBuilder private var policyGround: some View {
        switch setting.policy.ground(level) {
        case .legacy:
            legacy
        case .wallpaper(let minTint):
            CmuxMobileBackdrop(macTheme: macTheme, minTint: minTint, grouped: grouped)
        case .solid:
            Self.solid(grouped: grouped)
        }
    }

    static func solid(grouped: Bool) -> Color {
        CmuxMobileGroundRows.opaque(grouped ? CmuxMobileTheme.standard.colors.bgGrouped : CmuxMobileTheme.standard.colors.bg).color
    }
}

extension CmuxMobileGround where Legacy == Color {
    /// A ground whose legacy look is one color.
    public init(_ level: CmuxMobileGroundLevel, grouped: Bool = false, legacy: Color) {
        self.init(level, grouped: grouped) { legacy }
    }
}

public enum CmuxMobileGroundRows {
    /// Whether the policy shows the Mac's wallpaper at `level` now (rows go clear over it).
    public static func showsWallpaper(_ level: CmuxMobileGroundLevel,
                                       setting: CmuxMobileBackgroundSetting = .shared,
                                       macTheme: CmuxMobileMacTheme = .shared) -> Bool {
        guard macTheme.wallpaper != nil else { return false }
        if case .wallpaper = setting.policy.ground(level) { return true }
        return false
    }

    /// A list row's fill at `level`: `legacy` under Current, clear over the wallpaper, else the solid ground.
    public static func fill(_ level: CmuxMobileGroundLevel, legacy: UIColor) -> UIColor {
        let setting = CmuxMobileBackgroundSetting.shared
        if setting.policy == .current { return legacy }
        return showsWallpaper(level) ? .clear : opaque(CmuxMobileTheme.standard.colors.bg).uiColor
    }

    /// `token` at full opacity: a Mac theme's ground carries its window's opacity (a see-through
    /// window over the desktop), which on the phone would let a wallpaper drawn lower show through
    /// a screen the policy keeps solid.
    public static func opaque(_ token: CmuxMobileColorToken) -> CmuxMobileColorToken {
        func full(_ v: CmuxMobileRGBA) -> CmuxMobileRGBA { CmuxMobileRGBA(red: v.red, green: v.green, blue: v.blue) }
        return CmuxMobileColorToken(dark: full(token.dark), light: full(token.light),
                                    darkHighContrast: token.darkHighContrast.map(full), lightHighContrast: token.lightHighContrast.map(full))
    }
}
#endif
