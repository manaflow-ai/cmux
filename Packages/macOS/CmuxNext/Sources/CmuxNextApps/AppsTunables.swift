public import CmuxNextDesign

/// App Store layout prototypes (`apps.store.layout`, Debug Settings in DEV
/// and NIGHTLY; app-platform.md section 5). Lawrence picked cards (2026-10-02):
/// grid is the default; list and split stay as Debug variants.
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

/// How an app's sidebar section is framed (`apps.section.look`). Lawrence picked
/// card (2026-10-02); native and minimal stay as Debug variants.
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

/// How an App Store item card is drawn (`apps.store.cardStyle`): the same item primitive
/// (`AppStoreItemCard`) in three densities, for features and apps alike (Leo, 2026-10-22: "we
/// should also have nicer primitives for the app store").
public nonisolated enum AppStoreCardLook: String, Sendable, CaseIterable, TunableChoice {
    /// The preview over the name, two lines of description and the action row (the store's
    /// original density).
    case compact
    /// A tall preview, the name and one line, then the action row.
    case artwork
    /// One row: a small preview at the start, the name and one line, the actions at the end.
    case row

    public var tunableTitle: String {
        switch self {
        case .compact: "Compact (preview, two lines)"
        case .artwork: "Artwork (tall preview, one line)"
        case .row: "Row (small preview, actions at the end)"
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
        default: .card, code: "AppsTunables.sectionLook")

    public static let cardLook = Tunable<AppStoreCardLook>.choice(
        "apps.store.cardStyle", section, "App Store card style", help: "How feature and app cards are drawn. Switches live.",
        default: .compact, code: "AppsTunables.cardLook")

    public static var all: [TunableDescriptor] { [storeLayout.descriptor, sectionLook.descriptor, cardLook.descriptor] }
}
