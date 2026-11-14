import Foundation

/// Which drawings the cmux icon pack shows (Debug Settings `icons.family`). `pack` is the shipped
/// pack (design/icons/source). `custom` lays the cmux custom family over it (design/icons/source-custom,
/// Lucas 2026-10-17): the same names, redrawn in the agent chat's recipe, native and web alike.
/// `neko` reserves the optional theme identifier; its art is gallery-only until quality review.
/// Native icons read the family at launch; agent pages take it as a page attribute.
public nonisolated enum IconFamily: String, Sendable, CaseIterable, Hashable, TunableChoice {
    case pack
    case custom
    case neko

    // Unapproved artwork is not offered in Debug Settings either.
    public static var allCases: [IconFamily] { [.pack, .custom] }

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
        help: "The icon drawings: the shipped pack or cmux custom. Native icons change after a relaunch.",
        default: .pack, code: "IconFamily.tunable")
}
