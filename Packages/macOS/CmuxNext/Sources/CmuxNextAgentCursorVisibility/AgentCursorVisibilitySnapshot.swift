public import CoreGraphics

/// A rect in one window's content-view coordinates, flipped (origin
/// top-left, y down). Plain numbers, so the shared vectors read as JSON.
public nonisolated struct AgentCursorRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// What the visibility resolver reads: the facts about one target tab and
/// the windows that could show it, taken from the live models at the moment
/// an input event arrives. A value, so the rules replay from JSON
/// (schemas/agent-cursor-visibility/vectors.json) with no AppKit.
///
/// Every rect of a window is in that window's content-view coordinates,
/// flipped (the space of the window-level cursor host).
public nonisolated struct AgentCursorVisibilitySnapshot: Codable, Equatable, Sendable {
    /// Where the target tab lives; nil when no tab has the target id (closed).
    public var tab: TabLocation?
    /// Every window, front to back.
    public var windows: [Window]

    public init(tab: TabLocation?, windows: [Window]) {
        self.tab = tab
        self.windows = windows
    }

    public nonisolated struct TabLocation: Codable, Equatable, Sendable {
        public var workspace: String
        public var pane: String

        public init(workspace: String, pane: String) {
            self.workspace = workspace
            self.pane = pane
        }
    }

    public nonisolated struct Window: Codable, Equatable, Sendable {
        public var id: String
        /// The display the window is on (informational: a window on another
        /// display still draws).
        public var screen: String?
        public var minimized: Bool
        public var onActiveSpace: Bool
        /// The window content view's bounds (the cursor host's space).
        public var overlay: AgentCursorRect
        /// The workspace the window shows; nil while it shows none.
        public var shownWorkspace: String?
        /// Workspaces the window lists in its sidebar (shown and parked).
        public var listedWorkspaces: [String]
        public var sidebarHidden: Bool
        /// Sidebar row anchors by workspace id, computed from the sidebar
        /// layout (also for rows without a live view). A workspace in a
        /// collapsed group anchors at the group row; an unlisted one is absent.
        public var sidebarRows: [String: AgentCursorRect]
        /// Panes of the shown workspace that the layout measured.
        public var panes: [Pane]

        public init(id: String, screen: String? = nil, minimized: Bool = false, onActiveSpace: Bool = true,
                    overlay: AgentCursorRect, shownWorkspace: String?, listedWorkspaces: [String],
                    sidebarHidden: Bool = false, sidebarRows: [String: AgentCursorRect] = [:], panes: [Pane] = []) {
            self.id = id
            self.screen = screen
            self.minimized = minimized
            self.onActiveSpace = onActiveSpace
            self.overlay = overlay
            self.shownWorkspace = shownWorkspace
            self.listedWorkspaces = listedWorkspaces
            self.sidebarHidden = sidebarHidden
            self.sidebarRows = sidebarRows
            self.panes = panes
        }
    }

    public nonisolated struct Pane: Codable, Equatable, Sendable {
        public var id: String
        /// The pane's displayed frame; off the viewport for a column
        /// scrolled out. Nil when the pane is not on the active screen.
        public var frame: AgentCursorRect?
        /// Where the pane may show: the strip area not under docked columns
        /// (strip panes) or the screen (docked panes).
        public var clip: AgentCursorRect?
        public var selectedTab: String?
        /// The pane's tab strip.
        public var strip: AgentCursorRect?
        /// Tab chip anchors by tab id, clamped into the strip's tab area.
        public var chips: [String: AgentCursorRect]
        /// The selected tab's page viewport, when it is a laid-out page.
        public var page: Page?

        public init(id: String, frame: AgentCursorRect?, clip: AgentCursorRect?, selectedTab: String?,
                    strip: AgentCursorRect? = nil, chips: [String: AgentCursorRect] = [:], page: Page? = nil) {
            self.id = id
            self.frame = frame
            self.clip = clip
            self.selectedTab = selectedTab
            self.strip = strip
            self.chips = chips
            self.page = page
        }
    }

    public nonisolated struct Page: Codable, Equatable, Sendable {
        /// The page's own viewport: the page area minus docked DevTools.
        public var viewport: AgentCursorRect
        /// The tab's page zoom (`BrowserTabState.zoom`).
        public var zoom: Double

        public init(viewport: AgentCursorRect, zoom: Double) {
            self.viewport = viewport
            self.zoom = zoom
        }
    }
}
