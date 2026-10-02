public import CmuxNextActions
public import Observation

/// Sample data for every palette source, so the palette can be demoed and
/// tested without the App or the daemon. Records each call in `events`.
@Observable
public final class MockPaletteData: PaletteWorkspaceSource, PaletteTabSource, PaletteOpenInSource,
    PaletteSettingsSource, PaletteRecentDirectorySource, PaletteTargetSource
{
    public var workspaces: [PaletteWorkspace]
    public var tabs: [PaletteTab]
    public var apps: [PaletteOpenInApp]
    public var currentDirectory: String?
    public var toggles: [PaletteSettingToggle]
    public var recentDirectories: [String]
    public private(set) var events: [String] = []

    public init() {
        workspaces = [
            PaletteWorkspace(id: "w1", title: "cmux", directory: "/Users/demo/fun/cmux", isSelected: true),
            PaletteWorkspace(id: "w2", title: "cmux-tui daemon", directory: "/Users/demo/fun/cmux/cmux-tui", unreadCount: 2),
            PaletteWorkspace(id: "w3", title: "web dashboard", directory: "/Users/demo/fun/cmux/web"),
            PaletteWorkspace(id: "w4", title: "ghostty fork", directory: "/Users/demo/fun/ghostty"),
            PaletteWorkspace(id: "w5", title: "release notes", directory: "/Users/demo/Documents/notes", unreadCount: 1),
        ]
        tabs = [
            PaletteTab(id: "t1", title: "zsh", workspaceTitle: "cmux", isSelected: true),
            PaletteTab(id: "t2", title: "claude", workspaceTitle: "cmux"),
            PaletteTab(id: "t3", title: "localhost:3000", workspaceTitle: "web dashboard", kind: .browser),
            PaletteTab(id: "t4", title: "cargo watch", workspaceTitle: "cmux-tui daemon"),
            PaletteTab(id: "t5", title: "vim README.md", workspaceTitle: "release notes"),
        ]
        apps = [
            PaletteOpenInApp(id: "finder", name: "Finder", symbol: "folder"),
            PaletteOpenInApp(id: "vscode", name: "VS Code", symbol: "chevron.left.forwardslash.chevron.right"),
            PaletteOpenInApp(id: "zed", name: "Zed", symbol: "bolt.horizontal"),
            PaletteOpenInApp(id: "xcode", name: "Xcode", symbol: "hammer"),
            PaletteOpenInApp(id: "tower", name: "Tower", symbol: "arrow.triangle.branch"),
        ]
        currentDirectory = "/Users/demo/fun/cmux"
        toggles = [
            PaletteSettingToggle(id: "sidebar.minimal", title: "Minimal Sidebar", isOn: false, keywords: ["compact"]),
            PaletteSettingToggle(id: "notifications.sound", title: "Notification Sounds", isOn: true, keywords: ["audio"]),
            PaletteSettingToggle(id: "screens.enabled", title: "Screens", isOn: false, keywords: ["spaces"]),
            PaletteSettingToggle(id: "tabs.previews", title: "Tab Hover Previews", isOn: true, keywords: ["thumbnail"]),
        ]
        recentDirectories = [
            "/Users/demo/fun/cmux",
            "/Users/demo/fun/cmux/web",
            "/Users/demo/fun/zed",
            "/Users/demo/Documents/notes",
        ]
    }

    public func selectWorkspace(id: String) {
        events.append("selectWorkspace:\(id)")
        for index in workspaces.indices { workspaces[index].isSelected = workspaces[index].id == id }
    }

    public func renameWorkspace(id: String, to title: String) {
        events.append("renameWorkspace:\(id):\(title)")
        if let index = workspaces.firstIndex(where: { $0.id == id }) { workspaces[index].title = title }
    }

    public func closeWorkspace(id: String) {
        events.append("closeWorkspace:\(id)")
        workspaces.removeAll { $0.id == id }
    }

    public func selectTab(id: String) {
        events.append("selectTab:\(id)")
        for index in tabs.indices { tabs[index].isSelected = tabs[index].id == id }
    }

    public func renameTab(id: String, to title: String) {
        events.append("renameTab:\(id):\(title)")
        if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].title = title }
    }

    public func closeTab(id: String) {
        events.append("closeTab:\(id)")
        tabs.removeAll { $0.id == id }
    }

    public func open(appID: String) {
        events.append("openIn:\(appID)")
    }

    public func setToggle(id: String, isOn: Bool) {
        events.append("setToggle:\(id):\(isOn)")
        if let index = toggles.firstIndex(where: { $0.id == id }) { toggles[index].isOn = isOn }
    }

    public func openDirectory(_ path: String) {
        events.append("openDirectory:\(path)")
    }

    public func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        switch kind {
        case .workspace:
            workspaces.map { PaletteTargetOption(id: $0.id, title: $0.title, subtitle: $0.directory, symbol: "rectangle.stack") }
        case .tab:
            tabs.map { PaletteTargetOption(id: $0.id, title: $0.title, subtitle: $0.workspaceTitle, symbol: "terminal") }
        case .tabGroup:
            [
                PaletteTargetOption(id: "g1", title: "Review", subtitle: "3 tabs", symbol: "circle.fill"),
                PaletteTargetOption(id: "g2", title: "Servers", subtitle: "2 tabs", symbol: "circle.fill"),
            ]
        case .workspaceGroup:
            [PaletteTargetOption(id: "wg1", title: "cmux", symbol: "folder"), PaletteTargetOption(id: "wg2", title: "Personal", symbol: "folder")]
        case .window:
            [PaletteTargetOption(id: "win1", title: "Main Window", symbol: "macwindow")]
        case .machine:
            [PaletteTargetOption(id: "vm-1", title: "devbox", subtitle: "Cloud", symbol: "server.rack")]
        case .profile:
            [PaletteTargetOption(id: "default", title: "Default", symbol: "circle.fill"),
             PaletteTargetOption(id: "prof_work", title: "Work", symbol: "circle.fill")]
        case .browserProfile:
            [PaletteTargetOption(id: "default", title: "Default", symbol: "person.crop.circle"),
             PaletteTargetOption(id: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", title: "Work", symbol: "person.crop.circle")]
        case .bookmark:
            [PaletteTargetOption(id: "bm_0123456789abcdef0123456789abcdef", title: "cmux", symbol: "star")]
        case .pane, .column, .screen, .screenGroup, .sidebarItem, .sidebarSection:
            [PaletteTargetOption(id: "\(kind.rawValue)1", title: "\(kind.rawValue.capitalized) 1")]
        }
    }

    /// Sources wired to this mock.
    public var sources: PaletteSources {
        PaletteSources(workspaces: self, tabs: self, openIn: self, settings: self, recentDirectories: self, targets: self)
    }

    /// Binds a sample of catalog actions to handlers that record events, so
    /// a demo shows enabled rows next to the (debug-only) unbound ones.
    public func bindSampleActions(in registry: ActionRegistry) {
        let ids: [ActionID] = [
            "newTab", "newSurface", "closeTab", "splitRight", "splitDown", "toggleSidebar", "openSettings",
            "newWindow", "find", "toggleFullScreen", "nextSurface", "prevSurface", "equalizeSplits",
            "toggleSplitZoom", "showNotifications", "jumpToUnread", "reloadConfiguration", "openBrowser",
            "closeWorkspace", "focusLeft", "focusRight", "focusUp", "focusDown", "quit",
        ]
        for id in ids {
            registry.bind(id) { [weak self] in self?.events.append("action:\(id.rawValue)") }
        }
        registry.bind("renameTab", argumentHandler: { [weak self] in self?.events.append("renameTab:\($0)") }) {}
    }
}
