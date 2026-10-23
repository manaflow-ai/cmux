public import CmuxNextActions
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextDesign
public import Foundation
import CmuxNextAgentActivity
import CmuxNextHome
public import CmuxNextPages

extension PageDescriptor {
    /// The Chief view gallery (webviews/src/pages/chief-views): experimental views beside the Chief,
    /// over the agents the app already mirrors, the CI fleet dashboard and the repository's PRs.
    static let chiefViews = PageDescriptor(
        id: "cmux.chief-views", resource: "chief-views", namespaces: [ChiefViewsPageProvider.prefix])
}

/// What the gallery needs from the app: where the agents are and how to show one. The app passes
/// its machines and its navigation; nothing here holds an app object.
public struct ChiefViewsHost {
    /// Every workspace on every machine (`MachineRegistry.allWorkspaces`).
    var workspaces: @MainActor () -> [(WorkspaceModel, DaemonService)]
    /// A remote machine's display name.
    var machineName: @MainActor (DaemonService) -> String?
    /// Reveals an acpmux chat by session id (the `cmux://session/<id>` path).
    var openChat: @MainActor (String) throws -> Void
    /// Reveals a terminal tab by its id; false when it is gone.
    var revealTab: @MainActor (String) -> Bool
    /// Opens a pull request on Home's right side.
    var openURL: @MainActor (URL) -> Void

    public init(workspaces: @escaping @MainActor () -> [(WorkspaceModel, DaemonService)],
                machineName: @escaping @MainActor (DaemonService) -> String?,
                openChat: @escaping @MainActor (String) throws -> Void,
                revealTab: @escaping @MainActor (String) -> Bool,
                openURL: @escaping @MainActor (URL) -> Void) {
        self.workspaces = workspaces
        self.machineName = machineName
        self.openChat = openChat
        self.revealTab = revealTab
        self.openURL = openURL
    }
}

/// The Chief view gallery's page (cmux-page://cmux.chief-views/): one per tab. The views and
/// where each opens (pane, split or sidebar) are the page's own
/// (webviews/src/pages/chief-views/registry.ts); this serves their data
/// (``ChiefViewsPageProvider``). `chief.openViews` (palette, `cmux action run`) opens it as a page
/// tab, which in the home workspace lands in Home's right column beside the Chief dock.
@MainActor
public final class ChiefViewsPage {
    public static let actionID: ActionID = "chief.openViews"
    public static let symbol = "square.grid.2x2"
    /// The tab's title.
    public static var title: String { ChiefViewsStrings.title }
    /// Why `chief.openViews` is unavailable: Release and RC, or Debug Settings > Home >
    /// "Chief view gallery" off. Nil when it opens.
    public static var unavailableReason: String? {
        DevTools.isEnabled && ChiefViewsTunables.gallery.value ? nil : ChiefViewsStrings.off
    }
    /// The gallery's Debug Settings rows.
    public nonisolated static var tunables: [TunableDescriptor] { ChiefViewsTunables.all }

    private let host: ChiefViewsHost
    private let lowPowerMode: LowPowerMode

    /// - Parameters:
    ///   - host: The app's machines and navigation the page reads and drives.
    ///   - lowPowerMode: The app's Low Power Mode, which the page renders by.
    public init(host: ChiefViewsHost, lowPowerMode: LowPowerMode) {
        self.host = host
        self.lowPowerMode = lowPowerMode
    }

    /// A new page view with its own provider; nil when the page's bundle is missing.
    public func makeView() -> PageWebView? {
        let provider = ChiefViewsPageProvider(host: .live(host))
        return PageWebView(descriptor: .chiefViews, routes: [PageRoute(prefix: ChiefViewsPageProvider.prefix, provider: provider)],
                           lowPowerMode: lowPowerMode)
    }
}

extension ChiefViewsPageProvider.Host {
    /// The app's host: its lanes and tabs, the network, this app's defaults.
    static func live(_ app: ChiefViewsHost) -> Self {
        Self(
            agents: {
                ChiefViewsAgent.current(lanes: .shared, workspaces: app.workspaces(), machineName: app.machineName)
            },
            fetch: ChiefViewsPageProvider.liveFetch,
            defaults: .standard,
            environment: ProcessInfo.processInfo.environment,
            now: { Date() },
            openAgent: { kind, id in
                switch kind {
                case .chat: try app.openChat(id)
                case .terminal: guard app.revealTab(id) else { throw ActionFailure(message: ChiefViewsStrings.gone) }
                }
            },
            openURL: app.openURL)
    }
}

/// Debug Settings > Home > "Chief view gallery": on in DEV and NIGHTLY by default; Release and RC
/// never offer it (``ChiefViewsPage/unavailableReason``).
nonisolated enum ChiefViewsTunables {
    static let gallery = Tunable<Bool>.toggle(
        "home.chiefViewGallery", HomeTunables.section, "Chief view gallery",
        help: "Offers Chief View Gallery (palette): experimental views beside the Chief, such as where every agent is, an agent board, the CI fleet, landing PRs and today's timeline. One view is on at first; the gallery turns on the others.",
        default: true, code: "ChiefViewsTunables.gallery")

    static var all: [TunableDescriptor] { [gallery.descriptor] }
}

/// The gallery's native strings (table `ChiefViews`); the page's own text is
/// webviews/src/pages/chief-views/Localizable.xcstrings.
nonisolated enum ChiefViewsStrings {
    static var title: String { t("chiefViews.tab.title", "Views") }
    static var off: String {
        t("chiefViews.refusal.off", "The Chief view gallery is off. Turn on Chief view gallery in Debug Settings > Home.")
    }
    static var fleetUnset: String { t("chiefViews.fleet.unset", "No CI dashboard is set.") }
    static var fleetUnreachable: String { t("chiefViews.fleet.unreachable", "The CI dashboard did not answer.") }
    static var landingUnreachable: String {
        t("chiefViews.landing.unreachable", "GitHub did not answer. Try Refresh in a minute.")
    }
    static var gone: String { t("chiefViews.open.gone", "That agent is no longer running.") }
    static var untitledTerminal: String { t("chiefViews.terminal.untitled", "Terminal") }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ChiefViews", bundle: .module)
    }
}
