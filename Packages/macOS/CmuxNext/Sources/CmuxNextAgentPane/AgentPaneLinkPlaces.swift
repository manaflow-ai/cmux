import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSettings
public import Foundation

/// The workspaces, panes and tabs a pasted cmux link can name (`cmux-nightly://workspace/ws_…`, Copy
/// Link to Workspace), by their resource ids, for every agent page's link chips (webviews
/// `chips/cmuxLinkPlaces.ts`, the `linkPlaces` push). Plumbing only: ``follow(_:)`` serializes the
/// workspace list the App already mirrors from every machine's daemon (`machines.allWorkspaces`, the
/// list `DeepLinkNavigator` opens such a link from); the page parses and draws. The page's only daemon
/// path is its host, and only the App holds every machine's tree.
///
/// App-wide like Needs you's marks, so ``AgentPaneAttentionTabs`` holds the one list
/// (``AgentPaneAttentionTabs/places``). Each page gets it at load and handshake and again on every
/// change, the whole latest list (the page keeps one map per push), held per pane to one per turn and
/// while nobody sees it (``AgentPaneShownPushes``). Ids and titles only, so a chip never asks per link.
@MainActor
public final class AgentPaneLinkPlaces {
    /// The App's list is ``AgentPaneAttentionTabs/places``; a test may use its own.
    public init() {}

    /// The places, in the order the App walked them (local machine first).
    public var places: [Place] = [] {
        didSet {
            guard places != oldValue else { return }
            for view in views.allObjects { view.shownPushes.push("linkPlaces", to: view) { [weak self] in self?.send(to: $0) } }
        }
    }
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    /// The App's watch (``follow(_:)``).
    private var watch: Task<Void, Never>?

    /// Most places one push carries (the page keeps as many, `MAX_PLACES`).
    public static let maximumPlaces = 4_096

    /// One workspace, pane or tab as a chip names it.
    public nonisolated struct Place: Hashable, Sendable {
        public enum Kind: String, Sendable { case workspace, pane, tab }
        /// `ws_…`, `pane_…` or `tab_…`.
        public var id: String
        public var kind: Kind
        public var title: String
        /// The machine it is on, nil for this Mac.
        public var host: String?
        /// A pane's or tab's workspace, by its title.
        public var workspace: String?

        public init(id: String, kind: Kind, title: String, host: String? = nil, workspace: String? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.host = host
            self.workspace = workspace
        }

        var json: JSONValue {
            var object: [String: JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue), "title": .string(title)]
            if let host { object["host"] = .string(host) }
            if let workspace { object["workspace"] = .string(workspace) }
            return .object(object)
        }
    }

    /// Keeps ``places`` on `workspaces` (every machine's workspaces, each with its machine's name when it
    /// is not this Mac), observed: nothing polls, and a change made in one main-actor turn is one list.
    /// Stops when `workspaces` answers nil (the App is gone) or the next call replaces it.
    public func follow(_ workspaces: @escaping @MainActor () -> [(WorkspaceModel, host: String?)]?) {
        watch?.cancel()
        // task-owner: the App's AgentPaneAttentionTabs (one per app); ends when `workspaces` answers nil or on the next follow
        watch = Task { [weak self] in
            for await next in ObservationStream({ workspaces().map(Self.places(in:)) }) {
                guard let next, let self else { return }
                places = next
            }
        }
    }

    /// The places of `workspaces`, named as the person knows them, at most ``maximumPlaces``: a
    /// workspace by its name (an unnamed one by its first tab, as its sidebar row reads), a pane by
    /// its name or the tab it opens on, a tab by its title. An item with no resource id (an older
    /// daemon) or no title names no link and is left out.
    static func places(in workspaces: [(WorkspaceModel, host: String?)]) -> [Place] {
        var places: [Place] = []
        for (workspace, host) in workspaces {
            let panes = workspace.screens.flatMap(\.panes)
            let front = panes.first.flatMap { Self.frontTab(of: $0) }?.displayTitle
            let name = workspace.isUnnamed ? (front.flatMap { $0.isEmpty ? nil : $0 } ?? workspace.displayName) : workspace.displayName
            if let id = workspace.resourceID?.rawValue {
                places.append(Place(id: id, kind: .workspace, title: name, host: host))
            }
            for pane in panes {
                let title = pane.name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.frontTab(of: pane)?.displayTitle ?? ""
                if let id = pane.resourceID?.rawValue, !title.isEmpty {
                    places.append(Place(id: id, kind: .pane, title: title, host: host, workspace: name))
                }
                for tab in pane.tabs {
                    guard let id = tab.resourceID?.rawValue, !tab.displayTitle.isEmpty else { continue }
                    places.append(Place(id: id, kind: .tab, title: tab.displayTitle, host: host, workspace: name))
                }
            }
            if places.count >= maximumPlaces { break }
        }
        return Array(places.prefix(maximumPlaces))
    }

    /// The tab `pane` opens on (the daemon's default), else its first.
    private static func frontTab(of pane: PaneModel) -> TabModel? {
        pane.tabs.enumerated().first { $0.offset == pane.defaultTabIndex }?.element ?? pane.tabs.first
    }

    /// The list, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        return .linkPlaces(places)
    }

    /// Pushes the list, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        let event = AgentPageEvent.linkPlaces(places)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyLinkPlaces?.(\(event.value.compactText));"])
    }
}

extension AgentPageEvent {
    /// The places a cmux link can name (`linkPlaces`): `[{id, kind, title, host?, workspace?}]`.
    static func linkPlaces(_ places: [AgentPaneLinkPlaces.Place]) -> AgentPageEvent {
        AgentPageEvent(kind: "linkPlaces", value: .array(places.map(\.json)))
    }
}
