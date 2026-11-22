/// A user-facing surface an app can appear on.
public nonisolated enum AppUserSurface: String, Sendable, Hashable, Codable, CaseIterable {
    case sidebar
    case palette
    /// Right-click and app menus.
    case menus
    /// Status items in the window titlebar.
    case titlebar
    /// Status items in the macOS menu bar.
    case menuBar
    /// "Open with" lists and menus (editors, viewers, openers).
    case openWith
    /// Items an app feeds into the shared feed (`cmux.feed.source/1`).
    case feeds
    /// App Store "Installed" badges.
    case storeBadges
}

/// One thing an app puts in front of the user, reduced to what the filter
/// needs (Platform v2 V1, V2): an implementation of an interface the shell
/// consumes (`cmux.section/1` for the sidebar, `cmux.status/1` for status
/// items, `cmux.editor/1` for open-with, ...), or an op from the app's
/// catalog fragment with the surfaces it declares.
public nonisolated struct AppPresenceItem: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        /// `implements: <interface>`; `placement` for `cmux.status/1` (`titlebar`, `menuBar`).
        case implementation(interface: String, placement: String?)
        /// A catalog fragment op and its declared user surfaces.
        case operation(op: String, surfaces: Set<AppUserSurface>)
    }

    public var appID: String
    /// Unique within the app (the implementation or op id).
    public var itemID: String
    public var source: Source

    public var id: String { "\(appID)#\(itemID)" }

    public init(appID: String, itemID: String, source: Source) {
        self.appID = appID
        self.itemID = itemID
        self.source = source
    }

    public static func implementation(_ appID: String, _ itemID: String, interface: String, placement: String? = nil) -> AppPresenceItem {
        AppPresenceItem(appID: appID, itemID: itemID, source: .implementation(interface: interface, placement: placement))
    }

    public static func operation(_ appID: String, _ op: String, surfaces: Set<AppUserSurface>) -> AppPresenceItem {
        AppPresenceItem(appID: appID, itemID: op, source: .operation(op: op, surfaces: surfaces))
    }

    /// The user surfaces this item appears on while its app is present.
    /// Interfaces the shell does not consume on a user surface (servers,
    /// credential and fs providers) appear on none.
    public var surfaces: Set<AppUserSurface> {
        switch source {
        case .operation(_, let surfaces):
            return surfaces.union([.storeBadges])
        case .implementation(let interface, let placement):
            let name = interface.split(separator: "/").first.map(String.init) ?? interface
            let places: Set<AppUserSurface> = switch name {
            case "cmux.section": [.sidebar, .palette, .menus]
            case "cmux.status": [placement == "menuBar" ? .menuBar : .titlebar]
            case "cmux.palette.scope", "cmux.search.provider": [.palette]
            case "cmux.editor", "cmux.viewer", "cmux.opener", "cmux.diff.renderer": [.openWith, .menus]
            case "cmux.feed.source": [.feeds]
            default: []
            }
            return places.union([.storeBadges])
        }
    }
}

/// The one central filter (critique C7): what each user surface shows and
/// whether a channel may run an app. Surfaces never filter on their own.
public nonisolated enum AppPresenceFilter {
    /// Apps with any presence on user surfaces: installed, enabled, not hidden.
    public static func isPresent(_ state: AppInstallState?) -> Bool {
        guard let state else { return false }
        return state.installed && state.enabled && !state.hidden
    }

    /// The apps every user surface may show: an allowlist, so an app with no
    /// record (never installed) is absent too. Surfaces and the catalog
    /// builder take this set; nothing filters on its own.
    public static func presentApps(_ states: [String: AppInstallState]) -> Set<String> {
        Set(states.values.filter(isPresent).map(\.appID))
    }

    /// The contributions `surface` shows.
    public static func visible(_ items: [AppPresenceItem], states: [String: AppInstallState],
                               on surface: AppUserSurface) -> [AppPresenceItem] {
        items.filter { isPresent(states[$0.appID]) && $0.surfaces.contains(surface) }
    }

    /// Whether `origin` may run the app (`app.run`, an MCP tool, an
    /// automation trigger). Disabled overrides everything; a hidden app
    /// runs only through the channels `hiddenAccess` allows.
    public static func run(_ appID: String, origin: AppRunOrigin,
                           states: [String: AppInstallState]) -> Result<Void, AppRunRefusal> {
        guard let state = states[appID], state.installed else { return .failure(.notInstalled) }
        guard state.enabled else { return .failure(.disabled) }
        guard state.hidden else { return .success(()) }
        let allowed = switch origin {
        case .user, .remote: false
        case .cli: state.hiddenAccess.cli
        case .mcp: state.hiddenAccess.mcp
        case .script: state.hiddenAccess.automations
        }
        return allowed ? .success(()) : .failure(.hidden)
    }
}
