import CmuxNextCompat
public import CmuxNextDaemon

/// The bar's rows of every workspace, kept for the app's life: a New Tab page reads its
/// open tabs, other workspaces and folders from here, so its open maps no workspace.
///
/// Each workspace's rows are one item of a feed (``ObservedItemsFeed``): a change maps the workspace that changed
/// and no other. A kept row has no icon: the icon of a row is read when a page lists it,
/// for the listed rows only. The app makes one holder, starts it once, and reads a page's lists from it:
///
/// ```swift
/// let kept = NewTabPlacesKept(home: NSHomeDirectory())
/// kept.follow(list: { workspaces }, rows: { rows(of: $0) }, changed: { refreshOpenPages() })
/// let lists = kept.places(current: workspaceID, excluding: pageID, limit: 40, icon: { icon(onMachine: $0, tab: $1) }) { walk() }
/// ```
@MainActor
public final class NewTabPlacesKept {
    /// Every workspace's rows, in the sidebar's order; nil before the feed's first rows.
    public private(set) var rows: [NewTabPlaces.Rows]?
    /// The folders of all kept workspaces, each once, in order. It is built again only when a workspace's own
    /// folders differ, so a read of it does not grow with the session.
    public private(set) var folders: [String] = []

    /// The text of each icon that a read made, by the icon's object: the next read makes no text again for an
    /// icon that did not change. It holds each object, so an id here is never of another object.
    private var icons: [ObjectIdentifier: (object: AnyObject, text: String?)] = [:]
    /// The most icon texts kept; at one more, all go and each next read makes its own again.
    public static let maximumIcons = 512

    private var feed: ObservedItemsFeed<WorkspaceModel, NewTabPlaces.Rows>?
    private var following: Task<Void, Never>?

    /// One workspace as the bar reads it, for the rows that the app keeps; a test gives one that counts its calls.
    public let source: @MainActor (WorkspaceModel) -> NewTabPlaces.Source
    /// This Mac's home folder: `~` in the kept rows, and never a project.
    public let home: String

    /// Creates an empty holder.
    /// - Parameters:
    ///   - home: This Mac's home folder.
    ///   - source: One workspace as the bar reads it.
    public init(home: String, source: @escaping @MainActor (WorkspaceModel) -> NewTabPlaces.Source = { NewTabPlaces.Source($0) }) {
        (self.home, self.source) = (home, source)
    }

    /// One workspace's rows for the bar, with no icon and with its machine: the map reads its workspace's own records only.
    /// - Parameters:
    ///   - workspace: One workspace of the store.
    ///   - machine: The machine that holds it; the icon of a listed row is looked up there.
    public func mapped(_ workspace: WorkspaceModel, machine: String?) -> NewTabPlaces.Rows {
        NewTabPlaces(home: home).rows(source(workspace), machine: machine)
    }

    /// Starts following the workspaces (once), for the app's life: their rows are kept from the first ones on.
    /// - Parameters:
    ///   - list: Every workspace, in the sidebar's order.
    ///   - rows: One workspace's rows. It runs for each workspace once, then for a workspace that changed.
    ///   - changed: Runs after the kept rows changed, the first ones included.
    public func follow(list: @escaping @MainActor @Sendable () -> [WorkspaceModel]?,
                       rows: @escaping @MainActor @Sendable (WorkspaceModel) -> NewTabPlaces.Rows?,
                       changed: @escaping @MainActor @Sendable () -> Void) {
        guard feed == nil else { return }
        // By object: two machines' workspaces may share an id (`handle:<n>` without the registry).
        let feed = ObservedItemsFeed<WorkspaceModel, NewTabPlaces.Rows>(list: list, id: { "\(ObjectIdentifier($0))" }, item: rows)
        self.feed = feed
        feed.start()
        // task-owner: the holder keeps the feed's rows for the app's life, as the feed itself lives.
        following = Task { [weak self] in
            for await items in ObservationStream({ ObservationTrigger(feed.observedItems) }) {
                guard let self else { return }
                guard let rows = items.value else { continue }
                self.keep(rows)
                changed()
            }
        }
    }

    /// The text of `object`, an icon: `make`'s result at the first call for this object, then the kept one.
    /// - Parameters:
    ///   - object: The icon's object; the same icon is the same object.
    ///   - make: The icon as the text that a page reads (a `data:` URL).
    public func icon(_ object: AnyObject, make: () -> String?) -> String? {
        let id = ObjectIdentifier(object)
        if let kept = icons[id] { return kept.text }
        if icons.count >= Self.maximumIcons { icons.removeAll(keepingCapacity: true) }
        let text = make()
        icons[id] = (object, text)
        return text
    }

    /// Takes the feed's rows (``follow(list:rows:changed:)`` calls it; a test may).
    /// - Parameter rows: Every workspace's rows, in the sidebar's order.
    public func keep(_ rows: [NewTabPlaces.Rows]) {
        let before = self.rows
        self.rows = rows
        if let before, before.count == rows.count, !zip(before, rows).contains(where: { $0.folders != $1.folders }) { return }
        folders = NewTabPlaces.folders(rows)
    }

    /// A New Tab page's lists from the kept rows (``NewTabPlaces/listed(_:current:excluding:limit:)``, and the
    /// folders, which have no limit). Before the feed's first rows the lists come from `walk`, which maps every
    /// workspace, as each page's open did before the rows were kept. The icons are read here, for the listed browser
    /// rows only.
    /// - Parameters:
    ///   - current: The workspace the page's window shows; it is not suggested.
    ///   - selectedID: The page's own tab, never suggested.
    ///   - limit: The most tab rows and the most workspace rows; nil for every row.
    ///   - icon: `(machine, tab id)`: the favicon of that machine's browser tab, as a `data:` URL.
    ///   - walk: Every workspace's rows, made now.
    public func places(current: String?, excluding selectedID: String?, limit: Int?, icon: (String?, String) -> String?,
                       walk: () -> [NewTabPlaces.Rows])
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String]) {
        let walked = rows == nil ? walk() : nil
        let listed = NewTabPlaces.listed(walked ?? rows ?? [], current: current, excluding: selectedID, limit: limit, icon: icon)
        return (listed.tabs, listed.workspaces, walked.map { NewTabPlaces.folders($0) } ?? folders)
    }
}
