import Foundation
import Synchronization

/// Which drawings the cmux icon pack shows (Debug Settings `icons.family`). `pack` is the shipped
/// pack (design/icons/source). `custom` lays the cmux custom family over it (design/icons/source-custom,
/// Lucas 2026-10-17): the same names, redrawn in the agent chat's recipe, native and web alike.
/// `neko` lays the optional cat family over it (design/icons/neko-candidates/round4, Leo: "we just want the
/// GOOD ones"); people turn it on with Settings > Appearance > Icon Theme (`appearance.iconTheme`), off by default.
/// Native icons read the family at launch; agent pages take it as a page attribute.
public nonisolated enum IconFamily: String, Sendable, CaseIterable, Hashable, TunableChoice {
    case pack
    case custom
    case neko

    /// The families with shipped artwork, which Debug Settings offers (design/icons/neko-evaluation.md).
    public static let shippedCases: [IconFamily] = [.pack, .custom, .neko]

    /// Debug Settings offers every family with shipped artwork.
    public static var tunableCases: [IconFamily] { shippedCases }

    /// Whether this family's artwork ships.
    public var isShipped: Bool { Self.shippedCases.contains(self) }

    /// `appearance.iconTheme` = neko, as cmux.json held it at launch (the App sets it before the first icon draws).
    public static func useNekoTheme(_ on: Bool) { nekoTheme.withLock { $0 = on } }

    /// The family icons draw with: the Debug Settings family when it is set, else Neko when Settings chose it.
    public static func effective(debug: IconFamily) -> IconFamily {
        debug == .pack && nekoTheme.withLock({ $0 }) ? .neko : debug
    }

    private static let nekoTheme = Mutex(false)

    public var tunableTitle: String {
        switch self {
        case .pack: "cmux pack (before)"
        case .custom: "cmux custom"
        case .neko: "Neko"
        }
    }

    /// The overlay `IconPack` merges for this family, and the page's `data-icon-family`; nil for the pack.
    public var overlay: String? { self == .pack ? nil : rawValue }

    public static let tunable = Tunable<IconFamily>.choice(
        "icons.family", .shape, "Icons: Family",
        help: "The icon drawings: the shipped pack, cmux custom or Neko. Native icons change after a relaunch.",
        default: .pack, code: "IconFamily.tunable")
}
