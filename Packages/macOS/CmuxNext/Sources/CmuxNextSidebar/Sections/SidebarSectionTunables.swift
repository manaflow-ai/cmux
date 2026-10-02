public import CmuxNextDesign
import Foundation

/// How sticky sections look (Debug Settings `sidebar.sections.look`, the
/// prototype switch; plans/cmux-next/sidebar-sections.md 7).
public nonisolated enum SectionsLookVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Icon + label rows with no fill at rest; a hairline separates sticky
    /// regions from the scrolling list.
    case quiet
    /// Each section of a sticky region sits in a rounded inset card.
    case card
    /// Built-in sections lay out as an icon grid (Arc favorites).
    case tray

    public var tunableTitle: String {
        switch self {
        case .quiet: "Quiet"
        case .card: "Card"
        case .tray: "Tray"
        }
    }
}

/// The user-facing noun for sections (prototype copy switch,
/// plans/cmux-next/sidebar-sections.md 2).
public nonisolated enum SectionsNoun: String, Sendable, CaseIterable, Hashable, TunableChoice {
    case sections
    case shelves

    public var tunableTitle: String {
        switch self {
        case .sections: "Sections"
        case .shelves: "Shelves"
        }
    }
}

/// Debug Settings switches of the sidebar sections prototype.
public nonisolated enum SidebarSectionTunables {
    public static let look = Tunable<SectionsLookVariant>.choice(
        "sidebar.sections.look", .sidebar, "Section look",
        help: "How sticky sidebar sections draw: quiet rows with a hairline, inset cards, or an icon tray for built-in items.",
        default: .quiet, code: "SidebarSectionTunables.look")
    public static let noun = Tunable<SectionsNoun>.choice(
        "sidebar.sections.noun", .sidebar, "Section noun",
        help: "Menu and palette copy: Sections or Shelves.",
        default: .sections, code: "SidebarSectionTunables.noun")
    public static let localPrototype = Tunable<Bool>.toggle(
        "sidebar.sections.localPrototype", .sidebar, "Edit sections locally",
        help: "Layout edits apply to an in-memory layout (never saved) until the daemon serves sidebar-layout-v1.",
        default: false, code: "SidebarSectionTunables.localPrototype")

    public static var all: [TunableDescriptor] { [look.descriptor, noun.descriptor, localPrototype.descriptor] }

    /// The live look: the Debug Settings override, else quiet.
    @MainActor public static var currentLook: SectionsLookVariant { look.override ?? look.defaultValue }
}
