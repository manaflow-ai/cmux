public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextBridge
public import CmuxNextDaemon
public import CmuxNextDaemonService
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

    public static func folderName(_ directory: String) -> String? {
        let name = URL(fileURLWithPath: directory).standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }
}
