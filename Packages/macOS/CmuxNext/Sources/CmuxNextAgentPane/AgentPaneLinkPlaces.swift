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

        var json: CmuxNextSettings.JSONValue {
            var object: [String: CmuxNextSettings.JSONValue] = ["id": .string(id), "kind": .string(kind.rawValue), "title": .string(title)]
            if let host { object["host"] = .string(host) }
            if let workspace { object["workspace"] = .string(workspace) }
            return .object(object)
        }
    }

    /// The names the person sees (review of #38166, F4): a workspace as its sidebar row and title bar
    /// name it (an unnamed one by its front tab), a tab as its strip names it (an agent chat by its
    /// chat's title, a page by its page's, never the `about:blank` its record carries). The App passes
    /// the sidebar's sources (`shownWorkspaceName`, `SidebarBridge.tabTitle`); ``records`` reads the
    /// records alone.
    public struct Titles {
        public var workspace: @MainActor (WorkspaceModel) -> String
        /// A tab's name in its workspace, made once per list (the sidebar's rule reads live stores).
        public var tabs: @MainActor () -> (WorkspaceModel, TabModel) -> String

        public init(workspace: @escaping @MainActor (WorkspaceModel) -> String,
                    tabs: @escaping @MainActor () -> (WorkspaceModel, TabModel) -> String) {
            self.workspace = workspace
            self.tabs = tabs
        }

        /// The records' own names (tests): an unnamed workspace by its front tab's record.
        public static var records: Titles {
            Titles(workspace: { workspace in
                let front = workspace.screens.flatMap(\.panes).first.flatMap { AgentPaneLinkPlaces.frontTab(of: $0) }?.displayTitle
                return workspace.isUnnamed ? (front.flatMap { $0.isEmpty ? nil : $0 } ?? workspace.displayName) : workspace.displayName
            }, tabs: { { _, tab in tab.displayTitle } })
        }
    }

    /// Keeps ``places`` on `workspaces` (every machine's workspaces, each with its machine's name when it
    /// is not this Mac), named by `titles`, observed: nothing polls, and a change made in one main-actor
    /// turn is one list. Stops when `workspaces` answers nil (the App is gone) or the next call replaces it.
    public func follow(_ workspaces: @escaping @MainActor () -> [(WorkspaceModel, host: String?)]?, titles: Titles) {
        watch?.cancel()
        // task-owner: the App's AgentPaneAttentionTabs (one per app); ends when `workspaces` answers nil or on the next follow
        watch = Task { [weak self] in
            for await next in ObservationStream({ workspaces().map { Self.places(in: $0, titles: titles) } }) {
                guard let next, let self else { return }
                places = next
            }
        }
    }

    /// The places of `workspaces`, named by `titles`, at most ``maximumPlaces``: a workspace by its
    /// shown name, a pane by its name or the tab it opens on, a tab by its shown title. An item with
    /// no resource id (an older daemon) or no name names no link and is left out.
    static func places(in workspaces: [(WorkspaceModel, host: String?)], titles: Titles = .records) -> [Place] {
        var places: [Place] = []
        let tabTitle = titles.tabs()
        for (workspace, host) in workspaces {
            let panes = workspace.screens.flatMap(\.panes)
            let name = titles.workspace(workspace)
            if let id = workspace.resourceID?.rawValue, !name.isEmpty {
                places.append(Place(id: id, kind: .workspace, title: name, host: host))
            }
            for pane in panes {
                let title = pane.name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.frontTab(of: pane).map { tabTitle(workspace, $0) } ?? ""
                if let id = pane.resourceID?.rawValue, !title.isEmpty {
                    places.append(Place(id: id, kind: .pane, title: title, host: host, workspace: name))
                }
                for tab in pane.tabs {
                    guard let id = tab.resourceID?.rawValue else { continue }
                    let title = tabTitle(workspace, tab)
                    if !title.isEmpty { places.append(Place(id: id, kind: .tab, title: title, host: host, workspace: name)) }
                }
            }
            if places.count >= maximumPlaces { break }
        }
        return Array(places.prefix(maximumPlaces))
    }

    /// The tab `pane` opens on (the daemon's default), else its first.
    fileprivate static func frontTab(of pane: PaneModel) -> TabModel? {
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
