public import CmuxNextDesign

/// App Store layout prototypes (`apps.store.layout`, Debug Settings in DEV
/// and NIGHTLY; app-platform.md section 5). Lawrence picks after dogfood.
public nonisolated enum AppStoreLayout: String, Sendable, CaseIterable, TunableChoice {
    /// Cards in a grid.
    case grid
    /// Dense rows.
    case list
    /// List and detail side by side.
    case split

    public var tunableTitle: String {
        switch self {
        case .grid: "Grid (cards)"
        case .list: "List (dense rows)"
        case .split: "Split (list + detail)"
        }
    }
}

/// How an app's sidebar section is framed (`apps.section.look`).
public nonisolated enum AppSectionLook: String, Sendable, CaseIterable, TunableChoice {
    /// Built-in row metrics, plain header: reads as a native section.
    case native
    /// A subtle inset card with the app icon in the header.
    case card
    /// Title only, no icon.
    case minimal

    public var tunableTitle: String {
        switch self {
        case .native: "Native (built-in rows)"
        case .card: "Card (inset, icon header)"
        case .minimal: "Minimal (title only)"
        }
    }
}

/// Debug Settings declarations of the app platform.
public nonisolated enum AppsTunables {
    public static let section = TunableSection(id: "apps", title: "Apps", symbol: "bag", order: 45)

    public static let storeLayout = Tunable<AppStoreLayout>.choice(
        "apps.store.layout", section, "App Store layout", help: "Prototype layout of the App Store window. Switches live.",
        default: .grid, code: "AppsTunables.storeLayout")

    public static let sectionLook = Tunable<AppSectionLook>.choice(
        "apps.section.look", section, "App section look", help: "How app sidebar sections and store previews are framed.",
        default: .native, code: "AppsTunables.sectionLook")

    public static var all: [TunableDescriptor] { [storeLayout.descriptor, sectionLook.descriptor] }
}
