import Foundation
import Observation

/// What a new workspace starts with.
public enum NewWorkspaceStart: Hashable, Sendable {
    /// The Mac's default: one terminal (cmux-tui `new-workspace`).
    case terminal
    /// An agent chat for a harness (`claude`, `codex`); "" is the Mac's default agent
    /// (New Agent Chat in a folder: a workspace whose only tab is the chat).
    case agent(String)
    /// A browser tab.
    case browser
}

/// One request to create a workspace.
public struct NewWorkspaceRequest: Hashable, Sendable {
    public var macID: String
    /// The working directory, or nil for the Mac's default (its home).
    public var directory: String?
    public var start: NewWorkspaceStart

    public init(macID: String, directory: String? = nil, start: NewWorkspaceStart = .terminal) {
        self.macID = macID
        self.directory = directory
        self.start = start
    }
}

/// The creation choices a backend supports on one Mac. The long-press menu
/// shows only these; everything else is hidden.
public struct WorkspaceCreationOptions: Hashable, Sendable {
    /// The phone may pick the working directory (recent directories).
    public var directories: Bool
    /// Agent harnesses that can be the first tab.
    public var agents: [String]
    /// A browser tab can be the first tab.
    public var browser: Bool
    /// Clone a git repository into the new workspace.
    public var cloneFromGit: Bool
    /// A plain tap reuses the last directory used here (else the Mac's default folder).
    public var tapUsesLastDirectory: Bool

    public init(directories: Bool = false, agents: [String] = [], browser: Bool = false, cloneFromGit: Bool = false,
                tapUsesLastDirectory: Bool = true) {
        self.directories = directories
        self.agents = agents
        self.browser = browser
        self.cloneFromGit = cloneFromGit
        self.tapUsesLastDirectory = tapUsesLastDirectory
    }

    /// Only the default (a terminal in the Mac's home).
    public static let basic = WorkspaceCreationOptions()
}

/// A refusal the user sees ("Couldn't create a workspace on <Mac>: <message>").
public struct WorkspaceCreationError: Error, Hashable, Sendable, LocalizedError {
    public var message: String
    /// The message is written for the person (the phone's own words, or the Mac's
    /// reason it shows them too), so a toast shows it as is.
    public var isForPerson: Bool
    public init(_ message: String, isForPerson: Bool = false) {
        self.message = message
        self.isForPerson = isForPerson
    }
    public var errorDescription: String? { message }
}

/// A tab the phone can open in a workspace on its Mac.
public enum NewTabKind: Hashable, Sendable {
    case terminal
    /// An agent chat: the Mac's default agent, or a chosen harness and model.
    case agent(AgentChatStart)
    case browser

    /// The same kind, whatever agent or model it starts (for "is this kind offered").
    public var family: String {
        switch self {
        case .terminal: "terminal"
        case .agent: "agent"
        case .browser: "browser"
        }
    }
}

/// A tab group change from a tab's menu, in the Mac's words (its tab menu and
/// `TabGroupActionCatalog`): every one acts on the tab's own group except `create` and `add`.
public enum TabGroupEdit: Hashable, Sendable {
    /// New Tab Group: a group of this tab alone (`create-tab-group`).
    case create
    /// Add Tab to Group…: into a group of the same workspace (`add-tabs-to-tab-group`).
    case add(group: String)
    /// Remove Tab from Group (`remove-tabs-from-tab-group`).
    case remove
    /// Rename Tab Group… (`update-tab-group {name}`).
    case rename(String)
    /// Ungroup Tabs: the group goes, its tabs stay (`ungroup-tab-group`).
    case ungroup
    /// Close Tab Group: closes every tab in it (`close-tab-group`).
    case close
    /// Pin Group: saves it on the Mac so it can be reopened (`save-tab-group`).
    case save
    /// Unpin Group (`unsave-tab-group`).
    case unsave
    /// Set Tab Group Color…: one of the Mac's group colors (`update-tab-group {color}`).
    case setColor(String)
    /// Set Tab Group Icon… (an SF Symbol or one emoji) or, with nil, Remove Tab Group Icon
    /// (`update-tab-group {icon}`, null removes it).
    case setIcon(String?)
    /// Collapse Tab Group / Expand Tab Group (`update-tab-group {collapsed}`).
    case setCollapsed(Bool)
    /// Move Tab Group Left / Right: past the neighboring tab or group in its pane (`move-tab-group`).
    case moveLeft
    case moveRight
    /// Move Tab Group to New Split: a new pane on that side of the group's pane (`move-tab-group-to-split`).
    case moveToSplit(TabGroupEdge)
    /// Move Tab Group to New Column (`move-tab-group-to-column`).
    case moveToColumn
    /// Move Tab Group to New Workspace (`move-tab-group-to-new-workspace`).
    case moveToNewWorkspace
    /// Move Tab Group to Workspace…: into that workspace's shown pane, at its end (`move-tab-group`).
    case moveToWorkspace(String)

    /// The Mac's menu title.
    public var title: String {
        switch self {
        case .create: "New Tab Group"
        case .add: "Add Tab to Group…"
        case .remove: "Remove Tab from Group"
        case .rename: "Rename Tab Group…"
        case .ungroup: "Ungroup Tabs"
        case .close: "Close Tab Group"
        case .save: "Pin Group"
        case .unsave: "Unpin Group"
        case .setColor: "Set Tab Group Color…"
        case .setIcon(let icon): icon == nil ? "Remove Tab Group Icon" : "Set Tab Group Icon…"
        case .setCollapsed(let collapsed): collapsed ? "Collapse Tab Group" : "Expand Tab Group"
        case .moveLeft: "Move Tab Group Left"
        case .moveRight: "Move Tab Group Right"
        case .moveToSplit: "Move Tab Group to New Split"
        case .moveToColumn: "Move Tab Group to New Column"
        case .moveToNewWorkspace: "Move Tab Group to New Workspace"
        case .moveToWorkspace: "Move Tab Group to Workspace…"
        }
    }

    /// Moves the whole group somewhere else (a split, column or workspace); its tabs stay together.
    public var movesGroup: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveToSplit, .moveToColumn, .moveToNewWorkspace, .moveToWorkspace: true
        default: false
        }
    }
}

/// The side of the group's pane that Move Tab Group to New Split opens a pane on (the Mac's
/// direction argument), named as the phone's split menus name it.
public enum TabGroupEdge: String, Hashable, Sendable, CaseIterable, Identifiable {
    case right, left, up, down
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .right: "To the Right"
        case .left: "To the Left"
        case .up: "Above"
        case .down: "Below"
        }
    }

    /// The daemon's `edge` (`PaneEdge`).
    public var wire: String {
        switch self {
        case .right: "right"
        case .left: "left"
        case .up: "top"
        case .down: "bottom"
        }
    }

    public var systemImage: String {
        switch self {
        case .right: "rectangle.righthalf.inset.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .up: "rectangle.tophalf.inset.filled"
        case .down: "rectangle.bottomhalf.inset.filled"
        }
    }
}

/// A tab group saved on the Mac (its Pin Group), as Reopen Saved Tab Group… and Delete
/// Saved Tab Group… list it (`list-saved-tab-groups`).
public struct SavedTabGroup: Hashable, Sendable, Identifiable {
    public var id: String
    /// Empty: the Mac shows the color only.
    public var name: String
    public var color: String
    public var terminals: Int
    public var browsers: Int
    /// A live group is linked to it: the Mac refuses to reopen it ("the saved group is already open").
    public var isOpen: Bool

    public init(id: String, name: String = "", color: String = "grey", terminals: Int = 0, browsers: Int = 0, isOpen: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.terminals = terminals
        self.browsers = browsers
        self.isOpen = isOpen
    }

    /// The group's name, else its color ("Red group"), as the Mac's own groups read.
    public var displayName: String { WorkspaceTab.TabGroupRef(id: id, name: name, color: color).displayName }

    /// What reopening it brings back: "2 terminals, 1 browser tab".
    public var summary: String {
        var parts: [String] = []
        if terminals > 0 { parts.append(terminals == 1 ? "1 terminal" : "\(terminals) terminals") }
        if browsers > 0 { parts.append(browsers == 1 ? "1 browser tab" : "\(browsers) browser tabs") }
        return parts.isEmpty ? "No tabs" : parts.joined(separator: ", ")
    }
}

/// Reopen Saved Tab Group… / Delete Saved Tab Group… (the Mac's `TabGroupActionCatalog`).
public enum SavedTabGroupAction: String, Hashable, Sendable, Identifiable {
    case reopen, delete
    public var id: String { rawValue }

    /// The Mac's menu title.
    public var title: String {
        switch self {
        case .reopen: "Reopen Saved Tab Group…"
        case .delete: "Delete Saved Tab Group…"
        }
    }

    /// The chooser's title (the menu title without its ellipsis).
    public var sheetTitle: String { String(title.dropLast()) }

    /// The Mac's refusal of a reopen whose group is already open (`savedGroupAlreadyOpen`).
    public static let alreadyOpen = "The saved group is already open."
    /// The Mac's refusal when the record is gone (`savedTabGroupGone`).
    public static let gone = "That saved tab group no longer exists."
}

/// Where workspaces are really created: the mock store, or a Mac's daemon.
@MainActor
public protocol WorkspaceCreationBackend: AnyObject {
    /// Whether this backend can create on `macID` right now (online, linked).
    func canCreate(on macID: String) -> Bool
    /// What the long-press menu may offer on `macID`.
    func options(on macID: String) -> WorkspaceCreationOptions
    /// Creates the workspace. `placeholder` is the optimistic row already in
    /// the list; return the real workspace (the placeholder itself when the
    /// backend keeps its ids).
    func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace
    /// Whether this backend can rename and close workspaces on `macID` now.
    func canManage(on macID: String) -> Bool
    /// Renames a workspace on its Mac.
    func rename(_ workspace: Workspace, to title: String) async throws
    /// Closes a workspace on its Mac.
    func close(_ workspace: Workspace) async throws
    /// Duplicate Workspace: a new workspace on the Mac with the same terminals (each a new
    /// shell in its tab's folder) and web pages. Returns it once the Mac lists it.
    func duplicate(_ workspace: Workspace) async throws -> Workspace
    /// The tabs the phone may open in a workspace on `macID` now (none: the
    /// new-tab menu says why instead of making a tab the Mac never sees).
    func tabKinds(on macID: String) -> [NewTabKind]
    /// Tab kinds the phone shows but can't open on `macID` now, each with why (an
    /// older Mac without browser streaming, agents not connected yet).
    func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)]
    /// The Mac's agents and models for a new agent chat, with what a phone can't start.
    func agentCatalog(on macID: String) async throws -> AgentCatalog
    /// Opens a tab on the Mac and returns it once the Mac lists it.
    func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab
    /// Closes a tab on the Mac.
    func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws
    /// The foreground programs other than the login shell in `tabs`' terminals, read from
    /// the Mac (`process-info`), unique and sorted; a terminal that does not answer in
    /// time counts as idle, as on the Mac.
    func runningPrograms(of tabs: [WorkspaceTab], in workspace: Workspace) async -> [String]
    /// Whether tabs can be renamed, duplicated and moved on `macID` now.
    func canEditTabs(on macID: String) -> Bool
    /// Renames a tab on the Mac (the phone never sends an empty name).
    func renameTab(_ tab: WorkspaceTab, in workspace: Workspace, to title: String) async throws
    /// Opens a copy of a tab next to it on the Mac (a terminal in its pane's folder,
    /// the same page in a browser tab) and returns it once the Mac lists it.
    func duplicateTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab
    /// A page's link that opens a new tab or window (`rb.open_tab`: `target=_blank`,
    /// `window.open`, the page menu's Open Link in New Tab): a browser tab at `url` in the
    /// pane of `tab`, the page that asked, returned once the Mac lists it.
    func openBrowserTab(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab
    /// A web link tapped in a terminal: a cmux browser tab at `url` beside the terminal, in its
    /// pane, as the Mac's Cmd-click opens it (`new-browser-tab {url, pane}`). Returns the tab
    /// once the Mac lists it. Only `http` and `https` links reach the Mac.
    func openLink(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab
    /// Moves a tab to the place of `target` (its pane and position there).
    func moveTab(_ tab: WorkspaceTab, to target: WorkspaceTab, in workspace: Workspace) async throws
    /// Move Tab to Workspace… (`destination`) or Move Tab to New Workspace (nil, named as the
    /// Mac names it). Returns the workspace the tab is in now, once the Mac lists it.
    func moveTab(_ tab: WorkspaceTab, from workspace: Workspace, toWorkspace destination: Workspace?) async throws -> Workspace?
    /// Restart Shell Here: a terminal tab whose shell ended gets a new shell on the Mac,
    /// under the same tab (`restart-tab`).
    func restartShell(_ tab: WorkspaceTab, in workspace: Workspace) async throws
    /// Pin Tab / Unpin Tab.
    func setTabPinned(_ tab: WorkspaceTab, in workspace: Workspace, pinned: Bool) async throws
    /// A tab group change (`TabGroupEdit`).
    func editTabGroup(_ edit: TabGroupEdit, tab: WorkspaceTab, in workspace: Workspace) async throws
    /// The chat menu's Fork: a copy of the chat in a new tab beside it, returned once the Mac lists it.
    func forkAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab
    /// Edit and Resend of an earlier prompt: a copy of the chat through the turn whose
    /// `turn_result` is record `seq` (acpmux `acp.session.fork {throughSeq}`), in a new tab
    /// beside it, returned once the Mac lists it.
    func forkAgentChat(_ tab: WorkspaceTab, through seq: Int, in workspace: Workspace) async throws -> WorkspaceTab
    /// The chat menu's Archive: the chat is archived on the Mac and its tab closes.
    func archiveAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws
    /// The tab groups saved on `macID` (`list-saved-tab-groups`), each marked open when a live
    /// group links to it.
    func savedTabGroups(on macID: String) async throws -> [SavedTabGroup]
    /// Reopen Saved Tab Group…: the Mac reopens the saved group in `tab`'s pane
    /// (`reopen-saved-tab-group {saved, pane}`): its terminals as new shells in their saved
    /// folders (or the same terminal while it still runs), its browser tabs at their pages.
    func reopenSavedTabGroup(_ saved: SavedTabGroup, besides tab: WorkspaceTab, in workspace: Workspace) async throws
    /// Delete Saved Tab Group…: the record goes; an open group stays, unpinned (`delete-saved-tab-group {saved}`).
    func deleteSavedTabGroup(_ saved: SavedTabGroup, on macID: String) async throws
    /// Whether Move Tab Group Left (`forward` false) or Right can move `tab`'s group: not past
    /// its pane's edge or a pinned tab (the Mac's `TabGroupReorder`).
    func canMoveTabGroup(of tab: WorkspaceTab, forward: Bool, in workspace: Workspace) -> Bool
    /// New Tab in Group: a terminal in the group's pane, then into the group (`new-tab`,
    /// `add-tabs-to-tab-group`). Returns it once the Mac lists it.
    func newTabInGroup(of tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab
    /// Makes `screen` the workspace's active screen on the Mac, where the phone's new tabs open.
    func selectScreen(_ screen: MacScreen, in workspace: Workspace) async throws
    /// New Screen: a screen with a new terminal (`new-screen`). Returns its tab once the Mac lists it.
    func newScreen(in workspace: Workspace) async throws -> WorkspaceTab
    /// Rename Screen… (`rename-screen`; the phone never sends an empty name).
    func renameScreen(_ screen: MacScreen, in workspace: Workspace, to name: String) async throws
    /// Close Screen: its tabs close and their terminals end, as a tab closed on the phone ends
    /// its terminal (`close-screen {end_terminals}`).
    func closeScreen(_ screen: MacScreen, in workspace: Workspace) async throws
}

extension WorkspaceCreationBackend {
    public func forkAgentChat(_ tab: WorkspaceTab, through seq: Int, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("This Mac can't copy a chat up to an earlier message.", isForPerson: true)
    }

    public func restartShell(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func canManage(on macID: String) -> Bool { false }
    public func rename(_ workspace: Workspace, to title: String) async throws {
        throw WorkspaceCreationError("Renaming isn't available on this Mac")
    }
    public func close(_ workspace: Workspace) async throws {
        throw WorkspaceCreationError("Closing isn't available on this Mac")
    }
    public func duplicate(_ workspace: Workspace) async throws -> Workspace {
        throw WorkspaceCreationError("Duplicating isn't available on this Mac")
    }
    public func tabKinds(on macID: String) -> [NewTabKind] { [] }
    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] { [] }
    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func runningPrograms(of tabs: [WorkspaceTab], in workspace: Workspace) async -> [String] { [] }
    public func canEditTabs(on macID: String) -> Bool { false }
    public func renameTab(_ tab: WorkspaceTab, in workspace: Workspace, to title: String) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func duplicateTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func openBrowserTab(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func openLink(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func moveTab(_ tab: WorkspaceTab, to target: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func moveTab(_ tab: WorkspaceTab, from workspace: Workspace, toWorkspace destination: Workspace?) async throws -> Workspace? {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func setTabPinned(_ tab: WorkspaceTab, in workspace: Workspace, pinned: Bool) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func editTabGroup(_ edit: TabGroupEdit, tab: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func forkAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func archiveAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func savedTabGroups(on macID: String) async throws -> [SavedTabGroup] {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func reopenSavedTabGroup(_ saved: SavedTabGroup, besides tab: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func deleteSavedTabGroup(_ saved: SavedTabGroup, on macID: String) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func canMoveTabGroup(of tab: WorkspaceTab, forward: Bool, in workspace: Workspace) -> Bool { false }
    public func newTabInGroup(of tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func selectScreen(_ screen: MacScreen, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func newScreen(in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func renameScreen(_ screen: MacScreen, in workspace: Workspace, to name: String) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func closeScreen(_ screen: MacScreen, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
}

/// Recent working directories per Mac, newest first, persisted.
public struct RecentDirectories: @unchecked Sendable {
    private let defaults: UserDefaults
    public static let limit = 5

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ macID: String) -> String { "cmuxMobile.workspaces.recentDirectories.\(macID)" }

    public func load(macID: String) -> [String] {
        defaults.stringArray(forKey: key(macID)) ?? []
    }

    public func note(_ directory: String, macID: String) {
        var list = load(macID: macID).filter { $0 != directory }
        list.insert(directory, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key(macID))
    }
}

/// Instant workspace creation: a tap inserts an optimistic row, the caller
/// pushes it right away, and the backend confirms (the row becomes the real
/// workspace, and the open screen follows it) or refuses (the row is
/// removed and `onFailure` reports it).
@MainActor
@Observable
public final class WorkspaceCreator {
    public enum Phase: Hashable, Sendable {
        case pending
        /// Created; the real workspace id.
        case created(String)
        case failed(String)
    }

    /// By placeholder id.
    public private(set) var phases: [String: Phase] = [:]
    public var backend: any WorkspaceCreationBackend
    /// The Mac the next workspace goes to, when it can take one.
    public private(set) var preferredMacID: String?
    /// A creation the Mac refused: the removed placeholder and the reason.
    @ObservationIgnored public var onFailure: (@MainActor (Workspace, String) -> Void)?
    /// The placeholder's opening tab became the Mac's real tab (`from`,
    /// `to`): a page the person already opened in it keeps going under the
    /// real id (a streamed browser tab, verify/redial-video.md).
    @ObservationIgnored public var onTabResolved: (@MainActor (_ from: String, _ to: String) -> Void)?
    /// A rename or close the Mac refused: the workspace, what failed
    /// ("Couldn't close cmux") and the reason. The change is already undone.
    @ObservationIgnored public var onManageFailure: (@MainActor (Workspace, String, String) -> Void)?
    @ObservationIgnored let store: AppStore
    @ObservationIgnored private let recents: RecentDirectories
    /// A Mac's workspace folders by activity, kept until the workspaces change
    /// (the New Workspace menu reads them on every list update).
    @ObservationIgnored private var seenCache: (macID: String, revision: Int, pending: Set<String>, directories: [String])?

    /// The Mac's distinct workspace folders, most recent activity first (at
    /// most `limit`): one pass over the workspaces, then a sort of the folders.
    private func seenDirectories(on macID: String, limit: Int) -> [String] {
        let workspaces = store.workspaces
        let (revision, pending) = (store.workspacesRevision, store.pendingWorkspaceIDs)
        if let cache = seenCache, cache.macID == macID, cache.revision == revision, cache.pending == pending { return cache.directories }
        var newest: [String: Date] = [:]
        for ws in workspaces where ws.macID == macID && !ws.directory.isEmpty && !pending.contains(ws.id) {
            if let known = newest[ws.directory], known >= ws.lastActivityAt { continue }
            newest[ws.directory] = ws.lastActivityAt
        }
        let directories = Array(newest.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
        seenCache = (macID, revision, pending, directories)
        return directories
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// The last group request of each Mac: group requests go to a Mac one
    /// after another, so the Mac applies quick taps in the order they came.
    @ObservationIgnored var groupRequestTail: [String: Task<Void, Never>] = [:]
    private static let preferredMacKey = "cmuxMobile.workspaces.newMac"

    public init(store: AppStore, backend: any WorkspaceCreationBackend, defaults: UserDefaults = .standard) {
        self.store = store
        self.backend = backend
        self.defaults = defaults
        recents = RecentDirectories(defaults: defaults)
        preferredMacID = defaults.string(forKey: Self.preferredMacKey)
    }

    /// The active team's Macs this backend can create on, in team order.
    public var availableMacs: [MacDevice] {
        (store.activeTeam?.listedMacs ?? []).filter { $0.isOnline && backend.canCreate(on: $0.id) }
    }

    /// The preferred Mac when available, else the first available one.
    public var targetMac: MacDevice? {
        let macs = availableMacs
        return macs.first { $0.id == preferredMacID } ?? macs.first
    }

    /// Remembers the Mac new workspaces go to (the menu's Mac picker).
    public func prefer(macID: String) {
        guard preferredMacID != macID else { return }
        preferredMacID = macID
        defaults.set(macID, forKey: Self.preferredMacKey)
    }

    public func options(on macID: String) -> WorkspaceCreationOptions {
        backend.options(on: macID)
    }

    /// Recent directories on a Mac: ones used for new workspaces from this
    /// phone, then the Mac's workspaces by activity. Empty when the backend
    /// cannot choose a directory.
    public func recentDirectories(on macID: String) -> [String] {
        guard options(on: macID).directories else { return [] }
        let used = recents.load(macID: macID)
        let seen = seenDirectories(on: macID, limit: RecentDirectories.limit + used.count)
        var result: [String] = []
        for directory in used + seen where !result.contains(directory) {
            result.append(directory)
        }
        return Array(result.prefix(RecentDirectories.limit))
    }

    /// The directory a plain tap uses: the last one used on that Mac, else
    /// its home. Nil when the Mac picks (the backend cannot choose).
    public func defaultDirectory(on macID: String) -> String? {
        let options = options(on: macID)
        guard options.directories, options.tapUsesLastDirectory else { return nil }
        return recents.load(macID: macID).first ?? "~"
    }

    /// Starts creating a workspace and returns its optimistic placeholder,
    /// already in the list, to push. Nil when no Mac can take it or the
    /// start is not supported there.
    @discardableResult
    public func create(start: NewWorkspaceStart = .terminal, directory: String? = nil, macID: String? = nil) -> Workspace? {
        guard let mac = macID.flatMap({ id in availableMacs.first { $0.id == id } }) ?? targetMac else { return nil }
        let options = options(on: mac.id)
        switch start {
        case .terminal: break
        case .agent(let harness): guard options.agents.contains(harness) else { return nil }
        case .browser: guard options.browser else { return nil }
        }
        let dir = options.directories ? (directory ?? defaultDirectory(on: mac.id)) : nil
        let request = NewWorkspaceRequest(macID: mac.id, directory: dir, start: start)
        let placeholder = Self.placeholder(for: request, existing: store.workspaces.filter { $0.macID == mac.id }.map(\.title))
        store.insertPending(placeholder)
        store.requestFocusOnOpen(placeholder.id)
        phases[placeholder.id] = .pending
        if let dir { recents.note(dir, macID: mac.id) }
        tasks[placeholder.id] = Task { [weak self] in
            await self?.run(request, placeholder: placeholder)
        }
        return placeholder
    }

    /// Whether a workspace can be renamed or closed from this phone now:
    /// its Mac is online, the backend supports it, and it is not still
    /// being created.
    public func canManage(_ workspace: Workspace) -> Bool {
        guard !store.isPending(workspace.id),
              let mac = store.activeTeam?.macs.first(where: { $0.id == workspace.macID }), mac.isOnline else { return false }
        return backend.canManage(on: mac.id)
    }

    /// Renames at once; the old title comes back if the Mac refuses.
    public func rename(_ workspace: Workspace, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != workspace.title, canManage(workspace),
              let old = store.renameWorkspace(workspace.id, to: title) else { return }
        track(workspace.id) { [weak self] in
            do {
                try await self?.backend.rename(workspace, to: title)
            } catch {
                self?.store.renameWorkspace(workspace.id, to: old)
                self?.onManageFailure?(workspace, "Couldn't rename \(old)", Self.message(error))
            }
        }
    }

    /// Closes at once; the row comes back if the Mac refuses.
    public func close(_ workspace: Workspace) {
        guard canManage(workspace), let removed = store.removeWorkspace(workspace.id) else { return }
        track(workspace.id) { [weak self] in
            do {
                try await self?.backend.close(workspace)
            } catch {
                self?.store.restoreWorkspace(removed.workspace, at: removed.index)
                self?.onManageFailure?(workspace, "Couldn't close \(workspace.title)", Self.message(error))
            }
        }
    }

    /// The Mac's title for Duplicate Workspace (`action.workspace.duplicate`).
    public static let duplicateTitle = "Duplicate Workspace"

    /// Duplicate Workspace: the Mac makes the copy; the list shows it when the Mac lists it.
    /// Home has no duplicate (the Mac's Home is one workspace).
    public func duplicate(_ workspace: Workspace) {
        guard canDuplicate(workspace) else { return }
        track(workspace.id) { [weak self] in
            do {
                _ = try await self?.backend.duplicate(workspace)
            } catch {
                self?.onManageFailure?(workspace, "Couldn't duplicate \(workspace.title)", Self.message(error))
            }
        }
    }

    public func canDuplicate(_ workspace: Workspace) -> Bool { canManage(workspace) && !workspace.isHome }

    /// What this phone may do with a Mac's workspaces now, worked out once
    /// per Mac: a list asks it for every row (`canManage` looked the Mac up
    /// in the team for each one). A pending workspace is never managed.
    public struct MacRights: Equatable, Sendable {
        public var manage: Bool
        public var arrange: Bool
        public var group: Bool

        /// Nothing: an offline Mac, or one this backend cannot manage.
        public static let none = MacRights(manage: false, arrange: false, group: false)
    }

    public func rights(onMac macID: String) -> MacRights {
        guard let mac = store.activeTeam?.macs.first(where: { $0.id == macID }), mac.isOnline, backend.canManage(on: macID) else {
            return .none
        }
        let arrange = arranger?.canArrange(on: macID) ?? false
        return MacRights(manage: true, arrange: arrange, group: arrange && grouper != nil)
    }

    @discardableResult
    func track(_ id: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let key = "manage-\(id)-\(UUID().uuidString)"
        let task = Task { [weak self] in
            await work()
            self?.tasks[key] = nil
        }
        tasks[key] = task
        return task
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Waits for every creation in flight (tests and demos).
    public func settle() async {
        while let (id, task) = tasks.first {
            await task.value
            tasks[id] = nil
        }
    }

    private func run(_ request: NewWorkspaceRequest, placeholder: Workspace) async {
        defer { tasks[placeholder.id] = nil }
        do {
            let real = try await backend.create(request, placeholder: placeholder)
            store.resolvePending(placeholder.id, with: real)
            if let tab = Self.openingTab(of: real, for: request.start) {
                if request.start == .browser, let first = Self.openingTab(of: placeholder, for: request.start), first.id != tab.id {
                    onTabResolved?(first.id, tab.id)
                }
                store.noteOpened(tabID: tab.id, in: real.id)
            }
            phases[placeholder.id] = .created(real.id)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            store.removePending(placeholder.id)
            phases[placeholder.id] = .failed(message)
            onFailure?(placeholder, message)
        }
    }

    /// The tab the new workspace opens on: the first one of the requested kind.
    static func openingTab(of workspace: Workspace, for start: NewWorkspaceStart) -> WorkspaceTab? {
        let match: (WorkspaceTab) -> Bool = switch start {
        case .terminal: { $0.kind == .terminal }
        case .agent(let harness): { $0.kind == .agent && $0.harness == harness }
        case .browser: { $0.kind == .browser }
        }
        return workspace.tabs.first(where: match) ?? workspace.tabs.first
    }

    /// The optimistic workspace: titled after its directory (or "New
    /// Workspace"), unique on its Mac, with the requested first tab.
    public static func placeholder(for request: NewWorkspaceRequest, existing titles: [String], now: Date = Date()) -> Workspace {
        let id = "new-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = request.directory ?? "~"
        let base = Self.title(for: request.directory)
        let tabID = "\(id)-t1"
        let tab = switch request.start {
        case .terminal: WorkspaceTab(id: tabID, kind: .terminal, title: "zsh", subtitle: directory)
        case .agent(let harness):
            WorkspaceTab(id: tabID, kind: .agent, title: harness.isEmpty ? "Agent Chat" : harness == "codex" ? "Codex" : harness == "claude" ? "Claude" : harness.capitalized,
                         subtitle: "New session", harness: harness)
        case .browser: WorkspaceTab(id: tabID, kind: .browser, title: "New Tab")
        }
        return Workspace(id: id, macID: request.macID, title: uniqueTitle(base, existing: titles), directory: directory,
                         tabs: [tab], lastActivityAt: now)
    }

    static func title(for directory: String?) -> String {
        guard let directory, directory != "~", directory != "/" else { return "New Workspace" }
        let last = (directory as NSString).lastPathComponent
        return last.isEmpty || last == "~" ? "New Workspace" : last
    }

    /// "cmux", then "cmux 2", "cmux 3", …
    public static func uniqueTitle(_ base: String, existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// No Mac is linked: nothing can be created, and a request says so (never a
/// made-up workspace).
@MainActor
public final class UnavailableWorkspaceCreationBackend: WorkspaceCreationBackend {
    public init() {}

    public func canCreate(on macID: String) -> Bool { false }

    public func options(on macID: String) -> WorkspaceCreationOptions { WorkspaceCreationOptions() }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
}

#if DEBUG
/// Mock mode: every option, created after a short latency on an injected
/// clock. `failNext` makes the next creation fail (demo of the refusal path).
@MainActor
public final class MockWorkspaceCreationBackend: WorkspaceCreationBackend {
    public var failNext: String?
    private let clock: any Clock<Duration>
    private let latency: Duration

    public init(clock: any Clock<Duration> = ContinuousClock(), latency: Duration = .milliseconds(600)) {
        self.clock = clock
        self.latency = latency
    }

    public func canCreate(on macID: String) -> Bool { true }

    public func options(on macID: String) -> WorkspaceCreationOptions {
        WorkspaceCreationOptions(directories: true, agents: ["claude", "codex"], browser: true, cloneFromGit: false)
    }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        try await settle()
        return placeholder
    }

    public func canManage(on macID: String) -> Bool { true }

    public func rename(_ workspace: Workspace, to title: String) async throws {
        try await settle()
    }

    public func close(_ workspace: Workspace) async throws {
        try await settle()
    }

    /// The kinds this mock Mac opens (all of them by default).
    public var kinds: [NewTabKind] = [.agentChat, .terminal, .browser]
    /// The kinds it shows but can't open, with why (an older Mac, agents not up).
    public var unavailable: [(kind: NewTabKind, reason: String)] = []

    public func tabKinds(on macID: String) -> [NewTabKind] { kinds }

    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] { unavailable }

    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        AgentCatalog(harnesses: [
            AgentHarnessChoice(id: "claude", name: "Claude Code", family: "claude", isDefault: true,
                               models: [AgentModelChoice(id: "opus", name: "Opus"), AgentModelChoice(id: "sonnet", name: "Sonnet")],
                               defaultModel: "opus"),
            AgentHarnessChoice(id: "codex", name: "Codex", family: "codex", unavailableReason: AgentCatalog.refusedReason),
        ])
    }

    /// Mock mode only: the tab exists in the mock store alone.
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        let id = "t-\(UUID().uuidString.prefix(8).lowercased())"
        return switch kind {
        case .agent(let start):
            WorkspaceTab(id: id, kind: .agent, title: start.harness == "codex" ? "Codex" : "Claude", subtitle: "New session",
                         harness: start.harness ?? "claude")
        case .browser: WorkspaceTab(id: id, kind: .browser, title: "New Tab")
        case .terminal: WorkspaceTab(id: id, kind: .terminal, title: "zsh", subtitle: workspace.directory)
        }
    }

    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
    }

    public func canEditTabs(on macID: String) -> Bool { true }

    public func renameTab(_ tab: WorkspaceTab, in workspace: Workspace, to title: String) async throws {
        try await settle()
    }

    public func duplicateTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        return WorkspaceTab(id: "t-\(UUID().uuidString.prefix(8).lowercased())", kind: tab.kind, title: tab.title,
                     subtitle: tab.subtitle, harness: tab.harness, url: tab.url)
    }

    public func openBrowserTab(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        return WorkspaceTab(id: "t-\(UUID().uuidString.prefix(8).lowercased())", kind: .browser, title: url.host() ?? "New Tab", url: url)
    }

    /// Links a terminal opened in a browser tab, in order (tests).
    public private(set) var openedLinks: [URL] = []

    public func openLink(_ url: URL, besides tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        openedLinks.append(url)
        return WorkspaceTab(id: "t-\(UUID().uuidString.prefix(8).lowercased())", kind: .browser, title: url.host() ?? url.absoluteString, url: url)
    }

    public func moveTab(_ tab: WorkspaceTab, to target: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
    }

    /// Mock mode: the store moves the tab; a new workspace is the caller's to add.
    public func moveTab(_ tab: WorkspaceTab, from workspace: Workspace, toWorkspace destination: Workspace?) async throws -> Workspace? {
        try await settle()
        return destination
    }

    public func setTabPinned(_ tab: WorkspaceTab, in workspace: Workspace, pinned: Bool) async throws {
        try await settle()
    }

    /// Tabs Restart Shell Here was sent for, in order (tests).
    public private(set) var restartedShells: [String] = []

    public func restartShell(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
        restartedShells.append(tab.id)
    }

    /// Every edit the mock received, in order (tests).
    public private(set) var groupEdits: [TabGroupEdit] = []

    /// Workspaces duplicated, by id (tests).
    public private(set) var duplicated: [String] = []

    public func duplicate(_ workspace: Workspace) async throws -> Workspace {
        try await settle()
        duplicated.append(workspace.id)
        return workspace
    }

    /// The Mac's saved tab groups (Pin Group), for Reopen / Delete Saved Tab Group….
    public var savedGroups: [SavedTabGroup] = []
    /// Saved ids reopened, and the tab each was reopened beside (tests).
    public private(set) var reopenedGroups: [(saved: String, besides: String)] = []

    public func savedTabGroups(on macID: String) async throws -> [SavedTabGroup] {
        try await settle()
        return savedGroups
    }

    public func reopenSavedTabGroup(_ saved: SavedTabGroup, besides tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
        guard let index = savedGroups.firstIndex(where: { $0.id == saved.id }) else {
            throw WorkspaceCreationError(SavedTabGroupAction.gone, isForPerson: true)
        }
        reopenedGroups.append((saved.id, tab.id))
        savedGroups[index].isOpen = true
    }

    public func deleteSavedTabGroup(_ saved: SavedTabGroup, on macID: String) async throws {
        try await settle()
        savedGroups.removeAll { $0.id == saved.id }
    }

    public func editTabGroup(_ edit: TabGroupEdit, tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
        groupEdits.append(edit)
    }

    /// Mock mode: every group can move both ways.
    public func canMoveTabGroup(of tab: WorkspaceTab, forward: Bool, in workspace: Workspace) -> Bool { true }

    public func newTabInGroup(of tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        groupEdits.append(.add(group: tab.group?.id ?? ""))
        return WorkspaceTab(id: "t-\(UUID().uuidString.prefix(8).lowercased())", kind: .terminal, title: "Terminal", group: tab.group)
    }

    /// Screen changes the mock received, in order (tests): "select 2", "new", "rename 2 build", "close 2".
    public private(set) var screenEdits: [String] = []

    public func selectScreen(_ screen: MacScreen, in workspace: Workspace) async throws {
        try await settle()
        screenEdits.append("select \(screen.id)")
    }

    public func newScreen(in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        screenEdits.append("new")
        return WorkspaceTab(id: "t-\(UUID().uuidString.prefix(8).lowercased())", kind: .terminal, title: "Terminal")
    }

    public func renameScreen(_ screen: MacScreen, in workspace: Workspace, to name: String) async throws {
        try await settle()
        screenEdits.append("rename \(screen.id) \(name)")
    }

    public func closeScreen(_ screen: MacScreen, in workspace: Workspace) async throws {
        try await settle()
        screenEdits.append("close \(screen.id)")
    }

    public func forkAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        return WorkspaceTab(id: "t-\(UUID().uuidString.prefix(8).lowercased())", kind: .agent, title: tab.title, subtitle: "Fork",
                            harness: tab.harness)
    }

    public private(set) var archived: [String] = []

    public func archiveAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
        archived.append(tab.id)
    }

    private func settle() async throws {
        if latency > .zero { try await clock.sleep(for: latency) }
        if let message = failNext {
            failNext = nil
            throw WorkspaceCreationError(message)
        }
    }
}
#endif
