public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextBridge
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextLayout
public import CmuxNextSidebar
import Foundation

/// The sidebar surface needed by a workspace spawn callback. The app owns the
/// concrete bridge; the spawn value only depends on its read-only projection.
@MainActor
public protocol WorkspaceSpawnSidebar: AnyObject {
    var sections: [SidebarRowSection] { get }
}

/// What a new workspace's first terminal starts with. The keyboard, menu,
/// and palette pass nothing; the CLI (`cmux new-workspace`) passes a cwd,
/// name, command, and extra environment through `newTab`'s arguments.
public struct WorkspaceSpawn: Sendable {
    public var cwd: String?
    /// The new workspace's key, fixed by a caller that records the workspace before it exists (Import
    /// from Conductor, so a run cut off midway knows which workspace it half made); nil: a new key.
    public var key: WorkspaceKey?
    public var inheritedCwd: String?
    public var name: String?
    public var command: String?
    public var env: [String: String] = [:]
    public var keep = false
    public var profile: ProfileID?
    public var browserProfile: String?
    public var slot: WorkspaceSlot?
    public var placesBySetting = true
    /// False places a section create at the setting's top or bottom without inheriting the
    /// current workspace's group. The after-current setting still uses the current workspace.
    public var placesFromCurrent = true
    public var onListed: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)?
    public var opensNewTabPage = false
    public var firstChat: AgentPaneSeed?
    public var firstSession: String?
    public var inputToken: String?
    /// Work on the first terminal, inside the create (a browser workspace opens its tab, then closes
    /// the terminal; `WorkspaceHandlers.createAndShow`): a failure fails the create, which closes the
    /// workspace while it is still empty and releases its window's claim.
    public var onFirstTerminal: (@Sendable (DaemonConnection, CreateTerminalResult) async throws -> Void)?
    /// The workspace's only tab is this browser tab, made by the create itself on a daemon that serves
    /// `workspace-first-tab-v1` (one request, no terminal at any point); ``onFirstBrowser`` then works on
    /// the tab. An older daemon gets the terminal and ``onFirstTerminal``.
    public var firstBrowser: WorkspaceFirstBrowserTab?
    /// Work on the tab ``firstBrowser`` made, after the create; a failure is the create's.
    public var onFirstBrowser: (@Sendable (DaemonConnection, NewFrontendBrowserTabRequest.Response) async throws -> Void)?

    public init(cwd: String? = nil, name: String? = nil, command: String? = nil, env: [String: String] = [:], keep: Bool = false,
                profile: ProfileID? = nil, newTabPage: Bool = false, key: WorkspaceKey? = nil) {
        opensNewTabPage = newTabPage
        self.key = key
        self.cwd = cwd
        self.name = name
        self.command = command
        self.env = env
        self.keep = keep
        self.profile = profile
    }

    public init(opening directory: String?) {
        self.init(cwd: directory, name: directory.flatMap(Self.folderName))
    }

    public init(_ invocation: ActionInvocation) {
        cwd = invocation["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.flatMap(Self.folderName)
        command = invocation["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        keep = invocation["keep"]?.boolValue == true
        profile = invocation["profile"]?.targetValue.map { ProfileID(rawValue: $0.id) }
            ?? invocation["profile"]?.stringValue.flatMap { $0.isEmpty ? nil : ProfileID(rawValue: $0) }
        if let text = invocation["env"]?.stringValue, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            env = object.compactMapValues { $0 as? String }
        }
        opensNewTabPage = invocation.origin == .user && command == nil
    }

    /// One read of the placement `setting` for the create of `key` into `window`: tells the close-selection `rule` of
    /// the relation the create starts (``closeRelation(setting:)``), before the window can show it, and returns
    /// ``placement(setting:)``. A second read of the setting is a second walk of the sidebar's rows.
    @MainActor
    public func placement(setting: NewWorkspaceDefaultSlot, opening key: String, in window: String?,
                          tells rule: WindowCloseSelection) -> (row: NewWorkspaceDefaultSlot?, rule: NewWorkspaceDefaultSlot?) {
        if let window { rule.expect(key, in: window, relation: closeRelation(setting: setting)) }
        return placement(setting: setting)
    }

    /// The close-selection relation this create into a window starts (plans/cmux-next/close-focus.md, "One
    /// close-selection rule"). Rust decides (`WindowCloseSelection.relation`) from the facts given here: the
    /// create opens the New Tab page (a duplicate, a template, a move, a session transfer, an import and a
    /// command workspace never do), its run is the person's and may change the view, and the `setting` puts the
    /// new row after the current one. Only a person's own New Workspace gets one: `.task` after the current row
    /// (it lasts as a link tab's relation does), `.quick` at the top or the end (the quick look-up).
    public func closeRelation(setting: NewWorkspaceDefaultSlot) -> WindowCloseSelection.Relation {
        WindowCloseSelection.relation(opensNewTabPage: opensNewTabPage, personsAction: ActionRunScope.isPersonsAction(),
                                      mayChangeView: ActionRunScope.viewChangeAllowed(), afterCurrent: setting.placesAfterCurrent)
    }

    /// A plain Cmd-N: the New Tab page with nothing of its own (no key, chat, session, command, browser profile or
    /// folder), which may show the workspace reserved before the key (``DaemonStore/reservedWorkspaceUse(plain:home:)``).
    public var isPlainNewTabPage: Bool {
        opensNewTabPage && key == nil && firstChat == nil && firstSession == nil && command == nil && browserProfile == nil && cwd == nil
    }

    /// The folder the workspace starts in: its own, else (on this Mac) its room's default and then the folder it
    /// inherited, else the daemon's default.
    public func startFolder(roomFolder: String?, local: Bool, daemonDefault: String?) -> String? {
        cwd ?? (local ? roomFolder : nil).flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (local ? inheritedCwd : nil) ?? daemonDefault
    }

    /// The first terminal's environment: `app` (this Mac's launch identity; empty on a Cloud machine), then the room's
    /// `room`, then the caller's ``env``, then the placement keys hooks read (`CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`);
    /// a later one wins.
    public func terminalEnvironment(app: [String: String], room: [String: String]?, workspace: WorkspaceKey, terminal: TerminalID) -> [String: String] {
        var vars = app
        vars.merge(room ?? [:]) { _, profile in profile }
        vars.merge(env) { _, caller in caller }
        vars.merge(DaemonConnection.placementEnvironment(workspace: workspace, terminal: terminal)) { _, placement in placement }
        return vars
    }

    /// The name this create's row shows from the press: its own, else (only for a create into a window, which shows a
    /// row) the daemon's next default name `next()`; nil keeps the daemon's own numbering.
    public func rowName(inWindow: Bool, next: () -> String) -> String? {
        name ?? (inWindow ? next() : nil)
    }

    /// Whether the store can show this create's workspace before the daemon answers (`WorkspaceSpawner.shown`): the New
    /// Tab page, a chat or a session, with no command and no browser profile, and a folder of its own only on this Mac.
    public func showsBeforeDaemon(local: Bool) -> Bool {
        (opensNewTabPage || firstChat != nil || firstSession != nil) && command == nil && browserProfile == nil && (cwd == nil || local)
    }

    /// The default slot of this create's sidebar row and the rule it is placed by, from the window's
    /// `workspaces.newPlacement` rule `setting`: a create that does not place itself from the window's current
    /// workspace loses that anchor (except `afterCurrent`), and only a create placed by the setting gets a rule. A
    /// create with a slot of its own shows its row there (no default row) and keeps the rule only as the fallback for
    /// a slot whose anchor closed during the create: never the daemon's place, which can be the sidebar's end (Leo
    /// 2026-11-06).
    public func placement(setting: NewWorkspaceDefaultSlot) -> (row: NewWorkspaceDefaultSlot?, rule: NewWorkspaceDefaultSlot?) {
        let anchored = setting.anchored(fromCurrent: placesFromCurrent && placesBySetting)
        let row: NewWorkspaceDefaultSlot? = if case .none = slot { anchored } else { nil }
        return (row, placesBySetting ? anchored : nil)
    }

    /// What a new workspace's first terminal starts with (``TerminalStart``). On this Mac (`local`) it gets the app's
    /// environment `app` and the room's defaults `room`; on another machine only the caller's keys and that machine's
    /// default folder. The environment goes only to a daemon that takes one (`sendsEnv`), and `keep` only to one that
    /// reaps terminals (`reaps`).
    public func terminalStart(app: [String: String], room: ProfileDefaults?, local: Bool, daemonDefault: String?,
                              workspace: WorkspaceKey, terminal: TerminalID, sendsEnv: Bool, reaps: Bool) -> TerminalStart {
        let room = local ? room : nil
        return TerminalStart(env: sendsEnv ? terminalEnvironment(app: app, room: room?.env, workspace: workspace, terminal: terminal) : nil,
                             keep: keep && reaps ? true : nil, cwd: startFolder(roomFolder: room?.cwd, local: local, daemonDefault: daemonDefault))
    }

    public static func folderName(_ directory: String) -> String? {
        let name = URL(fileURLWithPath: directory).standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// What a new workspace's first terminal starts with (``WorkspaceSpawn/terminalStart(app:room:local:daemonDefault:workspace:terminal:sendsEnv:reaps:)``).
public struct TerminalStart: Sendable, Equatable {
    /// Its environment; nil for a daemon that takes none.
    public var env: [String: String]?
    /// True keeps it after its program exits; nil leaves the daemon's default.
    public var keep: Bool?
    /// The folder it starts in.
    public var cwd: String?

    public init(env: [String: String]?, keep: Bool?, cwd: String?) {
        self.env = env
        self.keep = keep
        self.cwd = cwd
    }
}

/// Whether a window that asks for a workspace of a Cloud machine waits for it (a relaunch: the machine list or its
/// daemon still loading) instead of replacing the request (`WindowController.showWorkspace`).
public struct CloudWorkspaceWait: Sendable, Equatable {
    /// Signed in to Cloud, or the sign-in is still restoring.
    public var signedIn: Bool
    /// The account's machine list has loaded.
    public var machinesLoaded: Bool
    /// Whether the machine runs (or starts); nil when it has no session.
    public var machineLive: Bool?
    /// Its daemon's tree is mirrored.
    public var mirrored: Bool

    public init(signedIn: Bool, machinesLoaded: Bool, machineLive: Bool?, mirrored: Bool) {
        self.signedIn = signedIn
        self.machinesLoaded = machinesLoaded
        self.machineLive = machineLive
        self.mirrored = mirrored
    }

    /// Waits while signed in and the list has not loaded, or while the machine runs and its tree is not mirrored yet.
    public var waits: Bool {
        guard signedIn else { return false }
        guard machinesLoaded else { return true }
        guard let machineLive else { return false }
        return machineLive && !mirrored
    }
}
