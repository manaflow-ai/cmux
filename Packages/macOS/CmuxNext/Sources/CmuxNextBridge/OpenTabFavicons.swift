import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
import Observation

/// The favicon address an open browser tab shows, by the tab's site origin: the first tab per origin in workspace
/// order, without the origins whose first tab shows the site's own `/favicon.ico` (a link draws that one without
/// storing it). What the sidebar's link items store (``SidebarDocMachines/followFavicons(_:revision:byOrigin:faviconKey:)``).
///
/// One observation per workspace (main-thread-scheduling.md section 3, O4): the workspace list is observed without
/// reading any workspace's fields, each workspace's open tab favicons are their own observation, and ``byOrigin`` is
/// written only when it changed. A navigation or a favicon change in one tab reads its workspace's tabs again, never
/// every tab of the store.
@Observable @MainActor public final class OpenTabFavicons {
    /// One open tab's favicon: its site origin and the favicon address it shows.
    nonisolated public struct Favicon: Equatable, Sendable {
        public var origin: String
        public var address: String
        public init(origin: String, address: String) {
            self.origin = origin
            self.address = address
        }
    }

    /// The joined table (read by an observer: written only when it changed).
    public private(set) var byOrigin: [String: String] = [:]
    @ObservationIgnored private var observed: ObservedItems<WorkspaceModel, [Favicon]>?
    @ObservationIgnored private var listed: [WorkspaceModel] = []
    @ObservationIgnored private var listTask: Task<Void, Never>?

    public init() {}

    /// Follows `workspaces` (the list only) and each workspace's tabs through `favicon` (nil: the tab gives none, as a
    /// terminal or an incognito page) from now on. Once; a second call does nothing.
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel],
                      favicon: @escaping @MainActor @Sendable (TabModel) -> Favicon?) {
        guard listTask == nil else { return }
        observed = ObservedItems(item: { workspace in Self.favicons(of: workspace, favicon: favicon) }, same: { $0 == $1 },
                                 changed: { [weak self] in self?.settle() })
        // task-owner: the app's services (live for the app); event-driven (Observation)
        listTask = Task { [weak self] in
            for await models in ObservationStream({ workspaces() }) {
                guard let self else { return }
                listed = models
                settle()
            }
        }
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

    /// The listed workspaces' favicons now: only workspaces new to the list are read (their own observations keep the
    /// rest); the table is written only when it changed.
    private func settle() {
        guard let observed else { return }
        let table = Self.table(observed.items(for: listed, id: { "\(ObjectIdentifier($0))" }))
        if byOrigin != table { byOrigin = table }
    }
}
