import Foundation

public struct TabSnapshot: Sendable, Hashable, Decodable {
    public var surface: SurfaceID
    public var tabResourceID: ResourceID?
    public var contentResourceID: ResourceID?
    public var terminalID: TerminalID?
    public var terminalResourceID: ResourceID?
    public var terminalIncarnation: TerminalIncarnation?
    public var shortID: String?
    public var kind: TabKind
    public var name: String?
    public var title: String
    public var size: CellSize?
    public var dead: Bool
    public var notification: TabNotification?
    public var url: String?
    public var browserSource: String?
    public var browserStatus: String?
    public var browserError: String?
    public var browserFramesStalled: Bool?
    /// Pinned tabs sort first in their pane (`tab-metadata-v1`).
    public var pinned: Bool
    /// Presented directory: last OSC 7 report or launch dir (`tab-metadata-v1`).
    public var cwd: String?
    /// Branch name, or the 7-char commit when `gitDetached` (`tab-metadata-v1`).
    public var gitBranch: String?
    public var gitDetached: Bool
    /// `"daemon"` (CDP), `"frontend"` (app-drawn), nil for PTYs (`frontend-browser-tabs-v1`).
    public var browserRenderer: String?
    /// `"webkit"` or `"cef"` for frontend browsers.
    public var browserEngine: String?
    public var faviconURL: String?
    public var browserProfileID: String?
    /// Tab group membership (`tab-groups-v1`, wire `group`).
    public var tabGroup: TabGroupID?
    /// The terminal a `remote-terminal` tab references (`remote-terminal-tabs-v1`).
    public var remote: RemoteTerminalRef?
    /// The workspace store's keep-layout record of a dead kept tab
    /// (`end-terminals-keep-layout-v1`).
    public var relaunch: TabRelaunch?

    public init(
        surface: SurfaceID,
        tabResourceID: ResourceID? = nil,
        contentResourceID: ResourceID? = nil,
        terminalID: TerminalID? = nil,
        terminalResourceID: ResourceID? = nil,
        terminalIncarnation: TerminalIncarnation? = nil,
        shortID: String? = nil,
        kind: TabKind = .pty,
        name: String? = nil,
        title: String = "",
        size: CellSize? = nil,
        dead: Bool = false,
        notification: TabNotification? = nil,
        url: String? = nil,
        pinned: Bool = false,
        cwd: String? = nil,
        gitBranch: String? = nil,
        gitDetached: Bool = false,
        browserRenderer: String? = nil,
        browserEngine: String? = nil,
        faviconURL: String? = nil,
        browserProfileID: String? = nil
    ) {
        self.surface = surface
        self.tabResourceID = tabResourceID
        self.contentResourceID = contentResourceID
        self.terminalID = terminalID
        self.terminalResourceID = terminalResourceID
        self.terminalIncarnation = terminalIncarnation
        self.shortID = shortID
        self.kind = kind
        self.name = name
        self.title = title
        self.size = size
        self.dead = dead
        self.notification = notification
        self.url = url
        self.pinned = pinned
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.gitDetached = gitDetached
        self.browserRenderer = browserRenderer
        self.browserEngine = browserEngine
        self.faviconURL = faviconURL
        self.browserProfileID = browserProfileID
    }

    /// Title a tab strip shows: the user name wins over the program title.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return title
    }

    /// True when the app draws this tab itself; `attach-surface` refuses it.
    public var isFrontendOwned: Bool {
        browserRenderer == "frontend" || kind == .remoteTerminal
    }

    enum CodingKeys: String, CodingKey {
        case surface, kind, name, title, size, dead, notification, url, pinned, cwd, remote, relaunch
        case tabResourceID = "tab_resource_id"
        case contentResourceID = "content_resource_id"
        case terminalID = "terminal_id"
        case terminalResourceID = "terminal_resource_id"
        case terminalIncarnation = "terminal_incarnation"
        case shortID = "short_id"
        case browserSource = "browser_source"
        case browserStatus = "browser_status"
        case browserError = "browser_error"
        case browserFramesStalled = "browser_frames_stalled"
        case gitBranch = "git_branch"
        case gitDetached = "git_detached"
        case browserRenderer = "browser_renderer"
        case browserEngine = "browser_engine"
        case faviconURL = "favicon_url"
        case browserProfileID = "browser_profile_id"
        case tabGroup = "group"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(SurfaceID.self, forKey: .surface)
        tabResourceID = try c.decodeIfPresent(ResourceID.self, forKey: .tabResourceID)
        contentResourceID = try c.decodeIfPresent(ResourceID.self, forKey: .contentResourceID)
        terminalID = try c.decodeIfPresent(TerminalID.self, forKey: .terminalID)
        terminalResourceID = try c.decodeIfPresent(ResourceID.self, forKey: .terminalResourceID)
        terminalIncarnation = try c.decodeIfPresent(TerminalIncarnation.self, forKey: .terminalIncarnation)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID)
        kind = try c.decodeIfPresent(TabKind.self, forKey: .kind) ?? .pty
        name = try c.decodeIfPresent(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        size = try c.decodeIfPresent(CellSize.self, forKey: .size)
        dead = try c.decodeIfPresent(Bool.self, forKey: .dead) ?? false
        notification = try c.decodeIfPresent(TabNotification.self, forKey: .notification)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        browserSource = try c.decodeIfPresent(String.self, forKey: .browserSource)
        browserStatus = try c.decodeIfPresent(String.self, forKey: .browserStatus)
        browserError = try c.decodeIfPresent(String.self, forKey: .browserError)
        browserFramesStalled = try c.decodeIfPresent(Bool.self, forKey: .browserFramesStalled)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        gitDetached = try c.decodeIfPresent(Bool.self, forKey: .gitDetached) ?? false
        browserRenderer = try c.decodeIfPresent(String.self, forKey: .browserRenderer)
        browserEngine = try c.decodeIfPresent(String.self, forKey: .browserEngine)
        faviconURL = try c.decodeIfPresent(String.self, forKey: .faviconURL)
        browserProfileID = try c.decodeIfPresent(String.self, forKey: .browserProfileID)
        tabGroup = try c.decodeIfPresent(TabGroupID.self, forKey: .tabGroup)
        remote = kind == .remoteTerminal ? try? c.decodeIfPresent(RemoteTerminalRef.self, forKey: .remote) : nil
        relaunch = try c.decodeIfPresent(TabRelaunch.self, forKey: .relaunch)
    }
}
