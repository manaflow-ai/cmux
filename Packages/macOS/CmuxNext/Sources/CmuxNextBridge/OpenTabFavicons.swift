public import CmuxNextDaemon
public import Foundation

/// The favicon address an open browser tab shows, by the tab's site origin: the first tab per origin in workspace
/// order, without the origins whose first tab shows the site's own `/favicon.ico` (a link draws that one without
/// storing it). What the sidebar's link items store (``SidebarDocMachines/followFavicons(_:revision:byOrigin:faviconKey:)``).
///
/// ``byOrigin`` reads every tab of every workspace each time it is read (the app's walk, moved here unchanged): an
/// observer of it is woken by a change in any tab of the store.
@MainActor public final class OpenTabFavicons {
    /// One open tab's favicon: its site origin and the favicon address it shows.
    nonisolated public struct Favicon: Equatable, Sendable {
        public var origin: String
        public var address: String
        public init(origin: String, address: String) {
            self.origin = origin
            self.address = address
        }
    }

    private var workspaces: (@MainActor @Sendable () -> [WorkspaceModel])?
    private var favicon: (@MainActor @Sendable (TabModel) -> Favicon?)?

    public init() {}

    /// The joined table: one walk of every tab of the listed workspaces, now.
    public var byOrigin: [String: String] {
        guard let workspaces, let favicon else { return [:] }
        return Self.table(workspaces().map { Self.favicons(of: $0, favicon: favicon) })
    }

    /// Follows `workspaces` and each workspace's tabs through `favicon` (nil: the tab gives none, as a terminal or an
    /// incognito page) from now on. Once; a second call does nothing.
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel],
                      favicon: @escaping @MainActor @Sendable (TabModel) -> Favicon?) {
        guard self.workspaces == nil else { return }
        self.workspaces = workspaces
        self.favicon = favicon
    }

    /// One workspace's open tab favicons, in model order.
    public static func favicons(of workspace: WorkspaceModel, favicon: @MainActor (TabModel) -> Favicon?) -> [Favicon] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(favicon)
    }

    /// `tab`'s favicon as an open tab gives it to the sidebar links: a browser tab that is not `incognito`, with a
    /// favicon address and a site origin (`faviconKey` of its page); nil for any other tab.
    public static func favicon(_ tab: TabModel, incognito: @MainActor (String) -> Bool, faviconKey: (URL) -> String?) -> Favicon? {
        guard tab.kind == .browser, let address = tab.faviconURL, !incognito(tab.id),
              let origin = tab.url.flatMap(URL.init(string:)).flatMap(faviconKey) else { return nil }
        return Favicon(origin: origin, address: address)
    }

    /// The table of `favicons` (workspace order): the first per origin, then without the site's own `/favicon.ico`.
    public static func table(_ favicons: [[Favicon]]) -> [String: String] {
        var byOrigin: [String: String] = [:]
        for favicon in favicons.joined() where byOrigin[favicon.origin] == nil {
            byOrigin[favicon.origin] = favicon.address
        }
        return byOrigin.filter { $0.value != $0.key + "/favicon.ico" }
    }
}
