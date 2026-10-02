public import CmuxNextDesign
import Foundation

/// How sticky sections look (Debug Settings `sidebar.sections.look`, the
/// prototype switch; plans/cmux-next/sidebar-sections.md 7).
public nonisolated enum SectionsLookVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Icon + label rows with no fill at rest; a hairline separates sticky
    /// bands from the scrolling list.
    case quiet
    /// Each section of a sticky band sits in a rounded inset card.
    case card
    /// Built-in sections lay out as an icon grid (Arc favorites).
    case tray
    /// No headers; a thin line between sections (a tonal step under
    /// `appearance.borders = none`).
    case lines
    /// Lines, and built-in sections show icons only.
    case linesIcons

    public var tunableTitle: String {
        switch self {
        case .quiet: "Quiet"
        case .card: "Card"
        case .tray: "Tray"
        case .lines: "Lines"
        case .linesIcons: "Lines, icons only"
        }
    }

    /// Whether section headers draw (Lawrence: few labels; the lines looks
    /// draw none).
    public var showsHeaders: Bool {
        switch self {
        case .quiet, .card, .tray: true
        case .lines, .linesIcons: false
        }
    }

    /// Whether a line separates one section from the next.
    public var separatesSections: Bool {
        switch self {
        case .lines, .linesIcons: true
        case .quiet, .card, .tray: false
        }
    }

    /// Whether a hairline separates the sticky bands from the list.
    public var drawsBandLines: Bool {
        switch self {
        case .quiet, .lines, .linesIcons: true
        case .card, .tray: false
        }
    }

    /// How icon-only sections tile.
    public enum Tiling: Sendable, Hashable {
        /// Stretched columns on a faint tile (tray).
        case grid
        /// Fixed-width icon buttons, leading (lines-icons).
        case buttons
    }

    /// The tiling `section` uses in this look, or nil for rows.
    public func tiling(_ section: LayoutSection) -> Tiling? {
        guard section.look == .builtIn else { return nil }
        switch self {
        case .tray: return .grid
        case .linesIcons: return .buttons
        case .quiet, .card, .lines: return nil
        }
    }
}

/// Debug Settings switches of the sidebar sections prototype.
public nonisolated enum SidebarSectionTunables {
    public static let look = Tunable<SectionsLookVariant>.choice(
        "sidebar.sections.look", .sidebar, "Section look",
        help: "How sticky sidebar sections draw: quiet rows with a hairline, inset cards, or an icon tray for built-in items.",
        default: .quiet, code: "SidebarSectionTunables.look")
    public static let localPrototype = Tunable<Bool>.toggle(
        "sidebar.sections.localPrototype", .sidebar, "Edit sections locally",
        help: "Layout edits apply to an in-memory layout (never saved) until the daemon serves sidebar-layout-v1.",
        default: false, code: "SidebarSectionTunables.localPrototype")

    public static var all: [TunableDescriptor] { [look.descriptor, localPrototype.descriptor] }

    /// The live look: the Debug Settings override, else `sidebar.sectionLook`
    /// in cmux.json (quiet by default).
    @MainActor public static var currentLook: SectionsLookVariant {
        look.override ?? SectionsLookVariant(rawValue: DesignSettings.shared.sidebarSections.look) ?? .quiet
    }
}
