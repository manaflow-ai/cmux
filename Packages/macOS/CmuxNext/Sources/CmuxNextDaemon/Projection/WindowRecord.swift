import Foundation

// Windows are frontend-local, so which workspace each window shows (and its
// frame) lives in a `personal` frontend projection, not the shared tree
// (plans/cmux-next/cmux-tui-contract.md 2.6, REWRITE.md "Tab drag"). The
// projection has its own CAS and exactly-once ledger and does not bump
// `workspace_revision`. Save on settle (window moved/resized, workspace
// switched), not per frame.

public struct WindowFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One restorable window.
public struct WindowRecord: Codable, Sendable, Hashable, Identifiable {
    /// Stable frontend-chosen window id (survives relaunch).
    public var id: String
    /// Workspace this window shows (durable key).
    public var workspaceKey: WorkspaceKey?
    /// Every workspace this window's sidebar lists, in order. Each workspace
    /// belongs to exactly one window. Empty in records from older builds,
    /// where every window listed every workspace.
    public var workspaceKeys: [WorkspaceKey]
    /// Machine whose daemon holds that workspace: nil for the local daemon,
    /// else a Cloud machine id. Lets a window wait for its machine to
    /// reconnect after relaunch instead of falling back to a local workspace.
    public var machine: String?
    /// Selected screen within that workspace (screen resource id).
    public var screenID: ResourceID?
    /// Screen coordinates (AppKit, bottom-left origin).
    public var frame: WindowFrame?
    /// Display UUID the window was on, to re-place it when the frame is off
    /// every connected screen.
    public var display: String?
    public var isFullScreen: Bool
    public var sidebarWidth: Double?
    /// The sidebar is hidden (zero width). Records from older builds store
    /// `sidebar_collapsed` (icons-only or hidden), which decodes as hidden:
    /// there is no icons-only sidebar anymore.
    public var sidebarHidden: Bool
    /// Selected tab per pane (pane resource id -> tab resource id).
    public var selectedTabs: [String: String]
    /// Front-to-back order key; lower is further front.
    public var order: Int
    /// Profile the window shows (plans/cmux-next/data-model.md 4); nil =
    /// `default` (records from builds without profiles).
    public var profile: ProfileID?
    /// The workspace this window last showed in each profile, so switching
    /// back restores it (profile id -> workspace key).
    public var profileWorkspaces: [String: WorkspaceKey]

    public init(id: String, workspaceKey: WorkspaceKey? = nil, workspaceKeys: [WorkspaceKey] = [], machine: String? = nil,
                screenID: ResourceID? = nil, frame: WindowFrame? = nil, display: String? = nil, isFullScreen: Bool = false,
                sidebarWidth: Double? = nil, sidebarHidden: Bool = false,
                selectedTabs: [String: String] = [:], order: Int = 0, profile: ProfileID? = nil,
                profileWorkspaces: [String: WorkspaceKey] = [:]) {
        self.id = id
        self.workspaceKey = workspaceKey
        self.workspaceKeys = workspaceKeys
        self.machine = machine
        self.screenID = screenID
        self.frame = frame
        self.display = display
        self.isFullScreen = isFullScreen
        self.sidebarWidth = sidebarWidth
        self.sidebarHidden = sidebarHidden
        self.selectedTabs = selectedTabs
        self.order = order
        self.profile = profile
        self.profileWorkspaces = profileWorkspaces
    }

    enum CodingKeys: String, CodingKey {
        case id, frame, order, machine, display, profile
        case profileWorkspaces = "profile_workspaces"
        case workspaceKey = "workspace_key"
        case workspaceKeys = "workspace_keys"
        case screenID = "screen_id"
        case isFullScreen = "full_screen"
        case sidebarWidth = "sidebar_width"
        case sidebarHidden = "sidebar_hidden"
        case selectedTabs = "selected_tabs"
    }

    /// Keys only older builds wrote; read for migration, never written.
    enum LegacyCodingKeys: String, CodingKey {
        case sidebarCollapsed = "sidebar_collapsed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceKey = try c.decodeIfPresent(WorkspaceKey.self, forKey: .workspaceKey)
        workspaceKeys = try c.decodeIfPresent([WorkspaceKey].self, forKey: .workspaceKeys) ?? []
        display = try c.decodeIfPresent(String.self, forKey: .display)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        screenID = try c.decodeIfPresent(ResourceID.self, forKey: .screenID)
        frame = try c.decodeIfPresent(WindowFrame.self, forKey: .frame)
        isFullScreen = try c.decodeIfPresent(Bool.self, forKey: .isFullScreen) ?? false
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        if let hidden = try c.decodeIfPresent(Bool.self, forKey: .sidebarHidden) {
            sidebarHidden = hidden
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            sidebarHidden = try legacy.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
        }
        selectedTabs = try c.decodeIfPresent([String: String].self, forKey: .selectedTabs) ?? [:]
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        profile = try c.decodeIfPresent(ProfileID.self, forKey: .profile)
        profileWorkspaces = try c.decodeIfPresent([String: WorkspaceKey].self, forKey: .profileWorkspaces) ?? [:]
    }
}
