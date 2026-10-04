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

    public static let history = Tunable<PageImplementation>.choice(
        "history.surface", section, "History page", help: "Shows cmux://history as the React page. New tabs use it.",
        default: .native, code: "PageTunables.history")

    /// The App Store tab as the React page (react-pages.md A1-A3). Its data comes from the app
    /// supervisor's `cmux.apps.*` ops; until the daemon serves them the page shows its
    /// disconnected state.
    public static let appStore = Tunable<PageImplementation>.choice(
        "apps.store.surface", section, "App Store page", help: "Shows the App Store tab as the React page. New tabs use it.",
        default: .native, code: "PageTunables.appStore")

    /// The Cloud page's machine list layout (the Cloud lead's prototype variants; rows default).
    public static let cloudMachinesLayout = Tunable<CloudMachinesLayout>.choice(
        "cloud.machines.layout", section, "Cloud machines layout", help: "Machine list of the Cloud page: dense rows or cards. New pages use it.",
        default: .rows, code: "PageTunables.cloudMachinesLayout")

    public static var all: [TunableDescriptor] { [history.descriptor, appStore.descriptor, cloudMachinesLayout.descriptor] }
}
