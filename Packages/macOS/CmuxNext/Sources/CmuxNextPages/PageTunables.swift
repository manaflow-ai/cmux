public import CmuxNextDesign

/// Which implementation a page uses while its React page replaces the Swift one
/// (plans/cmux-next/react-pages.md slices; DEV and NIGHTLY Debug Settings). The Swift page is
/// deleted when the React page becomes the default, and this tunable goes with it.
public nonisolated enum PageImplementation: String, Sendable, CaseIterable, TunableChoice {
    case native
    case web

    public var tunableTitle: String {
        switch self {
        case .native: "Native (Swift page)"
        case .web: "Web (React page)"
        }
    }
}

/// The Cloud page's machine list prototypes (webviews/src/pages/cloud README).
public nonisolated enum CloudMachinesLayout: String, Sendable, CaseIterable, TunableChoice {
    case rows
    case cards

    public var tunableTitle: String {
        switch self {
        case .rows: "Rows (dense)"
        case .cards: "Cards"
        }
    }
}

/// Debug Settings declarations of the React pages.
public nonisolated struct PageTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "pages", title: "Pages", symbol: "doc.richtext", order: 46)

    /// The Cloud page's machine list layout (the Cloud lead's prototype variants; rows default).
    public static let cloudMachinesLayout = Tunable<CloudMachinesLayout>.choice(
        "cloud.machines.layout", section, "Cloud machines layout", help: "Machine list of the Cloud page: dense rows or cards. New pages use it.",
        default: .rows, code: "PageTunables.cloudMachinesLayout")

    /// The App Store opens as the native AppKit store (Today, Discover, Categories, Updates,
    /// Installed) instead of the React page. Web stays the default until the native store reaches
    /// parity; nothing flips it but the owner's word.
    public static let appStore = Tunable<PageImplementation>.choice(
        "apps.store.surface", section, "App Store page", help: "Opens the App Store as the native store instead of the React page. New App Store tabs use it.",
        default: .web, code: "PageTunables.appStore")

    public static var all: [TunableDescriptor] { [cloudMachinesLayout.descriptor, appStore.descriptor, TabSwitchMorph.tunable.descriptor] }
}
