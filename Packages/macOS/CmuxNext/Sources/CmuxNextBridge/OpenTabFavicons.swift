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
/// every tab of the store. What a workspace's observation reads must be that workspace's own (its fields, its tabs, a
/// cell kept for it): a read of the store's tab index, its workspace list or the whole window registry there is woken
/// by a tab added in any workspace, once per workspace.
///
/// The work after one workspace's change does not grow with the session (the person's session has 826 workspaces): the
/// changed workspace's favicons arrive as one change (`ObservedItems.Change`), and the table is updated for that
/// workspace's sites only, from the places that hold each site (``SortedPositions``: the first holder gives the
/// favicon). Only a change of the workspace list reads the items of every workspace and builds the table again.
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
    /// Each listed workspace's favicons as its observation handed them out last, in list order.
    @ObservationIgnored private var items: [[Favicon]] = []
    /// By site origin: the places in ``items`` that have a favicon of that site.
    @ObservationIgnored private var holders: [String: SortedPositions] = [:]
    @ObservationIgnored private var listTask: Task<Void, Never>?

    public init() {}

    /// Follows `workspaces` (the list only) and each workspace through `favicons` (its open tab favicons in model order;
    /// the app: ``favicons(of:incognito:faviconKey:)``) from now on. `favicons` runs inside that workspace's
    /// observation, so it must read that workspace's own state only. Once; a second call does nothing.
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel],
                      favicons: @escaping @MainActor @Sendable (WorkspaceModel) -> [Favicon]) {
        guard listTask == nil else { return }
        observed = ObservedItems(item: { workspace in favicons(workspace) }, same: { $0 == $1 },
                                 changedItem: { [weak self] change in self?.itemChanged(change) })
        // task-owner: the app's services (live for the app); event-driven (Observation)
        listTask = Task { [weak self] in
            for await models in ObservationStream({ workspaces() }) {
                guard let self else { return }
                listed = models
                listChanged()
            }
        }
    }

    /// One workspace's open tab favicons, in model order.
    public static func favicons(of workspace: WorkspaceModel, favicon: @MainActor (TabModel) -> Favicon?) -> [Favicon] {
        workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(favicon)
    }

    /// One workspace's open tab favicons as the sidebar links get them, in model order: none for an `incognito` workspace
    /// (an incognito window's: every page of that window is incognito), else each browser tab's that has one
    /// (``favicon(_:faviconKey:)``). `incognito` is the caller's one read for the workspace, from the workspace's own
    /// facts (the app: `WindowManager.isIncognito(workspace:)` of the model: its `ephemeral` flag, its own registry cell,
    /// its claim), so the observation of a workspace that a window lists reads no session-wide state. A workspace that
    /// no window lists yet still reads the whole window registry there: that read is what lets it hear a new claim. A
    /// per-tab read (`BrowserTabService.isIncognitoTab`) found the workspace through the store's tab index, its
    /// workspace list and the whole window registry: one tab added anywhere woke every workspace's observation
    /// (#40213 review).
    public static func favicons(of workspace: WorkspaceModel, incognito: Bool, faviconKey: (URL) -> String?) -> [Favicon] {
        guard !incognito else { return [] }
        return favicons(of: workspace, favicon: { Self.favicon($0, faviconKey: faviconKey) })
    }

    /// `tab`'s favicon as an open tab gives it to the sidebar links: a browser tab with a favicon address and a site
    /// origin (`faviconKey` of its page); nil for any other tab. It reads the tab only: whether the tab is incognito is
    /// its workspace's fact (``favicons(of:incognito:faviconKey:)``).
    public static func favicon(_ tab: TabModel, faviconKey: (URL) -> String?) -> Favicon? {
        guard tab.kind == .browser, let address = tab.faviconURL,
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

    /// The workspace list changed: the listed workspaces' favicons now. Only workspaces new to the list are read (their
    /// own observations keep the rest), but every listed workspace is visited, so this runs for a list change only. The
    /// table is written only when it changed.
    private func listChanged() {
        guard let observed else { return }
        items = observed.items(for: listed, id: { "\(ObjectIdentifier($0))" })
        holders = [:]
        for (position, favicons) in items.enumerated() {
            for favicon in favicons { holders[favicon.origin, default: SortedPositions()].insert(position) }
        }
        let table = Self.table(items)
        if byOrigin != table { byOrigin = table }
    }

    /// One workspace's favicons changed: the table's entries of that workspace's sites (before and now) are found again
    /// from the first holder of each site, as ``table(_:)`` gives them. No other workspace is visited.
    private func itemChanged(_ change: ObservedItems<WorkspaceModel, [Favicon]>.Change) {
        // A place outside the items kept comes only from ids that are not unique (the place is then wrong): read the
        // list again, never keep a wrong table.
        guard items.indices.contains(change.position) else { return listChanged() }
        items[change.position] = change.new
        let before = Set(change.old.map(\.origin))
        let now = Set(change.new.map(\.origin))
        for origin in before.subtracting(now) {
            holders[origin]?.remove(change.position)
            if holders[origin]?.isEmpty == true { holders[origin] = nil }
        }
        for origin in now.subtracting(before) { holders[origin, default: SortedPositions()].insert(change.position) }
        let origins = before.union(now)
        ObservationWork.visited(origins.count, "OpenTabFavicons.join")
        for origin in origins {
            let address = holders[origin]?.first.flatMap { first in items[first].first { $0.origin == origin }?.address }
            let shown = address == origin + "/favicon.ico" ? nil : address
            if byOrigin[origin] != shown { byOrigin[origin] = shown }
        }
    }
}
