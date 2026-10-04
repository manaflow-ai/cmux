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

/// Debug Settings declarations of the React pages.
public nonisolated enum PageTunables {
    public static let section = TunableSection(id: "pages", title: "Pages", symbol: "doc.richtext", order: 46)

    public static let history = Tunable<PageImplementation>.choice(
        "history.surface", section, "History page", help: "Shows cmux://history as the React page. New tabs use it.",
        default: .native, code: "PageTunables.history")

    public static var all: [TunableDescriptor] { [history.descriptor] }
}
