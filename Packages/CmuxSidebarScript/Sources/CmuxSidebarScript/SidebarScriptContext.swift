import Foundation

/// The per-row data a script's `render-row` receives, as a host-friendly Swift
/// struct. The integration layer fills this from the existing sidebar snapshot;
/// `lispValue` projects it into the record the script sees.
///
/// Equatable so the integration can memoize: a row re-runs the script only when
/// its context changes.
public struct SidebarScriptContext: Equatable {
    public struct PullRequest: Equatable {
        public var number: Int
        public var state: String      // "open", "merged", "closed", "draft"
        public var url: String
        public var title: String?
        public var isDraft: Bool
        public var isStale: Bool
        public init(number: Int, state: String, url: String, title: String? = nil,
                    isDraft: Bool = false, isStale: Bool = false) {
            self.number = number
            self.state = state
            self.url = url
            self.title = title
            self.isDraft = isDraft
            self.isStale = isStale
        }
    }

    public struct StatusEntry: Equatable {
        public var label: String
        public var value: String
        public var colorHex: String?
        public init(label: String, value: String, colorHex: String? = nil) {
            self.label = label
            self.value = value
            self.colorHex = colorHex
        }
    }

    public var id: String?
    public var index: Int?
    public var title: String
    public var detail: String?
    public var branch: String?
    public var directory: String?
    public var directories: [String]
    public var pullRequests: [PullRequest]
    public var ports: [Int]
    public var unreadCount: Int
    public var isPinned: Bool
    public var isActive: Bool
    public var isSelected: Bool
    public var colorHex: String?
    public var isDarkMode: Bool
    public var latestMessage: String?
    public var progress: Double?
    public var remoteTarget: String?
    public var statusEntries: [StatusEntry]

    public init(
        id: String? = nil,
        index: Int? = nil,
        title: String,
        detail: String? = nil,
        branch: String? = nil,
        directory: String? = nil,
        directories: [String] = [],
        pullRequests: [PullRequest] = [],
        ports: [Int] = [],
        unreadCount: Int = 0,
        isPinned: Bool = false,
        isActive: Bool = false,
        isSelected: Bool = false,
        colorHex: String? = nil,
        isDarkMode: Bool = true,
        latestMessage: String? = nil,
        progress: Double? = nil,
        remoteTarget: String? = nil,
        statusEntries: [StatusEntry] = []
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.detail = detail
        self.branch = branch
        self.directory = directory
        self.directories = directories
        self.pullRequests = pullRequests
        self.ports = ports
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isActive = isActive
        self.isSelected = isSelected
        self.colorHex = colorHex
        self.isDarkMode = isDarkMode
        self.latestMessage = latestMessage
        self.progress = progress
        self.remoteTarget = remoteTarget
        self.statusEntries = statusEntries
    }

    /// Projects into the record passed to `render-row` as its single argument.
    public var lispValue: LispValue {
        var m = LispMap()
        m["id"] = id.map(LispValue.string) ?? .null
        m["index"] = index.map(LispValue.int) ?? .null
        m["title"] = .string(title)
        m["detail"] = detail.map(LispValue.string) ?? .null
        m["branch"] = branch.map(LispValue.string) ?? .null
        m["directory"] = directory.map(LispValue.string) ?? .null
        m["directories"] = .list(directories.map(LispValue.string))
        m["pull-requests"] = .list(pullRequests.map { pr in
            var p = LispMap()
            p["number"] = .int(pr.number)
            p["state"] = .string(pr.state)
            p["url"] = .string(pr.url)
            p["title"] = pr.title.map(LispValue.string) ?? .null
            p["draft"] = .bool(pr.isDraft)
            p["stale"] = .bool(pr.isStale)
            return .map(p)
        })
        m["ports"] = .list(ports.map(LispValue.int))
        m["unread"] = .int(unreadCount)
        m["pinned"] = .bool(isPinned)
        m["active"] = .bool(isActive)
        m["selected"] = .bool(isSelected)
        m["color"] = colorHex.map(LispValue.string) ?? .null
        m["dark-mode"] = .bool(isDarkMode)
        m["message"] = latestMessage.map(LispValue.string) ?? .null
        m["progress"] = progress.map(LispValue.double) ?? .null
        m["remote"] = remoteTarget.map(LispValue.string) ?? .null
        m["status"] = .list(statusEntries.map { entry in
            var s = LispMap()
            s["label"] = .string(entry.label)
            s["value"] = .string(entry.value)
            s["color"] = entry.colorHex.map(LispValue.string) ?? .null
            return .map(s)
        })
        return .map(m)
    }
}

/// Whole-sidebar data for scripts that define `render-sidebar`.
///
/// This is deliberately just data, not live app objects. The host turns it into
/// the same deterministic record format the row renderer uses, so a user script
/// can own the entire sidebar without gaining arbitrary app execution.
public struct SidebarScriptSidebarContext: Equatable {
    public var windowId: String?
    public var selectedWorkspaceId: String?
    public var workspaceCount: Int
    public var isDarkMode: Bool
    public var workspaces: [SidebarScriptContext]

    public init(
        windowId: String? = nil,
        selectedWorkspaceId: String? = nil,
        workspaceCount: Int? = nil,
        isDarkMode: Bool = true,
        workspaces: [SidebarScriptContext]
    ) {
        self.windowId = windowId
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaceCount = workspaceCount ?? workspaces.count
        self.isDarkMode = isDarkMode
        self.workspaces = workspaces
    }

    public var lispValue: LispValue {
        var m = LispMap()
        m["window-id"] = windowId.map(LispValue.string) ?? .null
        m["selected-workspace-id"] = selectedWorkspaceId.map(LispValue.string) ?? .null
        m["workspace-count"] = .int(workspaceCount)
        m["dark-mode"] = .bool(isDarkMode)
        m["workspaces"] = .list(workspaces.map(\.lispValue))
        return .map(m)
    }
}
