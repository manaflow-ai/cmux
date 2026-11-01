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

    public init(cwd: String? = nil, name: String? = nil, command: String? = nil, env: [String: String] = [:], keep: Bool = false,
                profile: ProfileID? = nil, newTabPage: Bool = false) {
        opensNewTabPage = newTabPage
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

    public static func folderName(_ directory: String) -> String? {
        let name = URL(fileURLWithPath: directory).standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }
}
