import CmuxNextOnboarding
import Foundation

/// One simulated classic cmux user: the session classic saved, written in
/// classic's own schema (`SessionPersistence.swift` on `main`), and what the
/// upgrade must bring over. ``ClassicUpgradeSimulationTests`` writes it into a
/// scratch Application Support folder and runs cmux-next's launch on it.
struct ClassicUpgradeProfile {
    /// A tab classic saved.
    enum Panel {
        case terminal(scrollback: String? = nil)
        case browser(String)
        /// Markdown or file preview: stays in classic.
        case viewer(String)
    }

    /// Classic's split tree.
    indirect enum Layout {
        case pane([Panel])
        case split(vertical: Bool, ratio: Double, Layout, Layout)

        /// Tabs cmux-next shows per pane, in tree order (viewers left out; a
        /// pane left with none closes up).
        var expectedPanes: [Int] {
            switch self {
            case .pane(let panels):
                let kept = panels.filter { if case .viewer = $0 { false } else { true } }.count
                return kept == 0 ? [] : [kept]
            case .split(_, _, let first, let second):
                return first.expectedPanes + second.expectedPanes
            }
        }
    }

    struct Group {
        var id: String
        var name: String
        var collapsed = false
        var pinned = false
        var color: String?
        var icon: String?
    }

    struct Workspace {
        var title: String?
        var folder: String = "~"
        var stableID: String? = UUID().uuidString
        var group: String?
        var pinned = false
        var color: String?
        var layout: Layout = .pane([.terminal()])
        /// `user@host` of an SSH workspace.
        var ssh: String?
        var cloudVM = false
        /// Stays in classic for another reason (an older Cloud VM saved as a websocket `remote`).
        var stays = false
        /// Extra raw keys merged into the saved workspace (damaged or unknown fields).
        var raw: [String: Any] = [:]

        /// Whether cmux-next makes it (Cloud VMs and viewer-only workspaces stay).
        var comesOver: Bool { !cloudVM && !stays && !layout.expectedPanes.isEmpty }
    }

    struct Window {
        var workspaces: [Workspace]
        var groups: [Group] = []
        var selected: Int? = 0
        var frame = CGRect(x: 120, y: 120, width: 1200, height: 800)
    }

    var name: String
    var windows: [Window]
    /// Classic before 2026-06 (always camelCase): no `stableId`/`workspaceId`,
    /// no groups, pins or colors, no panel `type`.
    var legacyKeys = false
    var createdAt: Double = 1_891_000_000

    // MARK: Writing classic's files

    /// The session file classic writes, as JSON. `home` replaces `~`.
    func sessionData(home: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: root(home: home), options: [.sortedKeys])
    }

    func root(home: String) -> [String: Any] {
        ["version": 1, "createdAt": createdAt, "windows": windows.map { window(for: $0, home: home) }]
    }

    private func key(_ camel: String) -> String { camel }

    private func window(for window: Window, home: String) -> [String: Any] {
        var manager: [String: Any] = [
            key("selectedWorkspaceIndex"): window.selected as Any? ?? NSNull(),
            key("workspaces"): window.workspaces.map { workspace(for: $0, home: home) },
        ]
        if !legacyKeys { manager["workspaceGroups"] = window.groups.map(group) }
        return [
            key("windowId"): UUID().uuidString,
            "frame": ["x": window.frame.minX, "y": window.frame.minY, "width": window.frame.width, "height": window.frame.height],
            "sidebar": ["isVisible": true, "width": 240],
            "tabManager": manager,
        ]
    }

    private func group(_ group: Group) -> [String: Any] {
        var value: [String: Any] = ["id": group.id, "name": group.name, key("isCollapsed"): group.collapsed, key("isPinned"): group.pinned]
        if let color = group.color { value[key("customColor")] = color }
        if let icon = group.icon { value[key("iconSymbol")] = icon }
        return value
    }

    private func workspace(for saved: Workspace, home: String) -> [String: Any] {
        let folder = saved.folder.replacingOccurrences(of: "~", with: home)
        var panels: [[String: Any]] = []
        let layout = self.layout(saved.layout, folder: folder, panels: &panels)
        var value: [String: Any] = [
            key("currentDirectory"): folder,
            "layout": layout,
            "panels": panels,
            key("isPinned"): saved.pinned,
            key("processTitle"): "~",
            key("layoutMode"): "splits",
            key("logEntries"): [Any](),
            key("statusEntries"): [Any](),
        ]
        if let title = saved.title {
            value[key("customTitle")] = title
            value[key("customTitleSource")] = "user"
        }
        if !legacyKeys, let stable = saved.stableID {
            value["stableId"] = stable
            value["workspaceId"] = UUID().uuidString
        }
        if !legacyKeys, let group = saved.group { value["groupId"] = group }
        if !legacyKeys, let color = saved.color { value["customColor"] = color }
        if let ssh = saved.ssh { value["remote"] = ["transport": "ssh", "destination": ssh] }
        if saved.cloudVM { value[key("cloudVM")] = [key("vmID"): "vm-\(UUID().uuidString.prefix(8))"] }
        for (field, raw) in saved.raw { value[field] = raw }
        return value
    }

    private func layout(_ layout: Layout, folder: String, panels: inout [[String: Any]]) -> [String: Any] {
        switch layout {
        case .pane(let tabs):
            var ids: [String] = []
            for tab in tabs {
                let id = UUID().uuidString
                ids.append(id)
                panels.append(panel(tab, id: id, folder: folder))
            }
            var pane: [String: Any] = [key("panelIds"): ids]
            if let first = ids.first { pane[key("selectedPanelId")] = first }
            return ["type": "pane", "pane": pane]
        case .split(let vertical, let ratio, let first, let second):
            return ["type": "split", "split": [
                "orientation": vertical ? "vertical" : "horizontal",
                key("dividerPosition"): ratio,
                "first": self.layout(first, folder: folder, panels: &panels),
                "second": self.layout(second, folder: folder, panels: &panels),
            ]]
        }
    }

    private func panel(_ tab: Panel, id: String, folder: String) -> [String: Any] {
        switch tab {
        case .terminal(let scrollback):
            var terminal: [String: Any] = [key("workingDirectory"): folder, key("isRemoteTerminal"): false]
            if let scrollback { terminal["scrollback"] = scrollback }
            // Classic's oldest snapshots name no panel type: a terminal.
            var value: [String: Any] = ["id": id, "directory": folder, "title": "~", "terminal": terminal]
            if !legacyKeys { value["type"] = "terminal" }
            return value
        case .browser(let url):
            return ["id": id, "type": "browser", "browser": [key("urlString"): url]]
        case .viewer(let type):
            return ["id": id, "type": type, "title": "README.md"]
        }
    }

    // MARK: What must come over

    /// Workspaces that come over, window by window, in sidebar order (each
    /// `stableId` once, the first one).
    var expectedWindows: [[Workspace]] {
        var seen = Set<String>()
        return windows.map { window in
            window.workspaces.filter { workspace in
                guard workspace.comesOver else { return false }
                guard let id = workspace.stableID, !legacyKeys else { return true }
                return seen.insert(id).inserted
            }
        }.filter { !$0.isEmpty }
    }

    var expectedCount: Int { expectedWindows.map(\.count).reduce(0, +) }

    /// Group names by classic group id.
    var groupNames: [String: String] {
        Dictionary(windows.flatMap(\.groups).filter { !$0.id.isEmpty }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

extension ClassicUpgradeProfile {
    /// A long but valid scrollback line block (with ANSI colors), `lines` lines.
    static func scrollback(lines: Int, width: Int = 100) -> String {
        let line = "\u{1b}[32m$\u{1b}[0m " + String(repeating: "x", count: max(0, width - 4))
        return Array(repeating: line, count: lines).joined(separator: "\r\n")
    }

    /// A split tree `depth` levels deep, alternating axes, `tabs` tabs per pane.
    static func nested(depth: Int, tabs: Int = 1, vertical: Bool = false) -> Layout {
        guard depth > 0 else { return .pane(Array(repeating: .terminal(), count: tabs)) }
        return .split(vertical: vertical, ratio: 0.5,
                      .pane(Array(repeating: .terminal(), count: tabs)),
                      nested(depth: depth - 1, tabs: tabs, vertical: !vertical))
    }

    // MARK: The profiles

    /// A person who installed classic and never set it up: one window, one shell.
    static var fresh: ClassicUpgradeProfile { ClassicUpgradeProfile(name: "fresh", windows: [Window(workspaces: [Workspace()])]) }

    static var small: ClassicUpgradeProfile { ClassicUpgradeProfile(name: "small", windows: [Window(
        workspaces: [
            Workspace(title: "api", folder: "~/proj/api", group: "G-WORK", color: "#FF6B6B",
                      layout: .split(vertical: false, ratio: 0.6, .pane([.terminal(), .terminal()]), .pane([.terminal()]))),
            Workspace(title: "web", folder: "~/proj/web", group: "G-WORK"),
            Workspace(title: "notes", pinned: true),
            Workspace(title: "db", folder: "~/proj/db"),
            Workspace(title: "scratch"),
        ],
        groups: [Group(id: "G-WORK", name: "Work", color: "#4ECDC4", icon: "hammer")], selected: 2)]) }

    /// Many groups: collapsed, pinned (one empty), colors, icons, members spread out.
    static var manyGroups: ClassicUpgradeProfile {
        let groups = (0..<12).map { index in
            Group(id: "G-\(index)", name: "Group \(index)", collapsed: index % 3 == 0, pinned: index % 4 == 1,
                  color: index % 2 == 0 ? "#3366FF" : nil, icon: index % 5 == 0 ? "star" : nil)
        }
        let workspaces = (0..<40).map { index in
            // Members use groups 0-10: group 11 stays empty, and is pinned below so it still comes over.
            Workspace(title: "member \(index)", group: index % 4 == 3 ? nil : "G-\(index % 11)", pinned: index % 9 == 0,
                      color: index % 7 == 0 ? "#AA00AA" : nil)
        }
        var all = groups
        all[11].pinned = true
        return ClassicUpgradeProfile(name: "manyGroups", windows: [Window(workspaces: workspaces, groups: all, selected: 17)])
    }

    static var nestedSplits: ClassicUpgradeProfile { ClassicUpgradeProfile(name: "nestedSplits", windows: [Window(workspaces: [
        Workspace(title: "deep 6", layout: nested(depth: 6)),
        Workspace(title: "deep 3 x3 tabs", layout: nested(depth: 3, tabs: 3, vertical: true)),
        Workspace(title: "grid", layout: .split(vertical: false, ratio: 0.5,
                                                .split(vertical: true, ratio: 0.3, .pane([.terminal()]), .pane([.terminal()])),
                                                .split(vertical: true, ratio: 0.7, .pane([.terminal()]), .pane([.terminal(), .terminal()])))),
        Workspace(title: "edge ratios", layout: .split(vertical: false, ratio: 0.01, .pane([.terminal()]), .pane([.terminal()]))),
    ])]) }

    static var browsersAndViewers: ClassicUpgradeProfile { ClassicUpgradeProfile(name: "browsersAndViewers", windows: [Window(workspaces: [
        Workspace(title: "docs", layout: .split(vertical: false, ratio: 0.5, .pane([.terminal()]),
                                                .pane([.browser("https://example.com/"), .browser("https://cmux.com/docs")]))),
        Workspace(title: "mixed", layout: .pane([.terminal(), .viewer("markdown"), .browser("https://example.org/")])),
        Workspace(title: "viewer only", layout: .pane([.viewer("markdown"), .viewer("filepreview")])),
        Workspace(title: "viewer split", layout: .split(vertical: true, ratio: 0.5, .pane([.viewer("markdown")]), .pane([.terminal()]))),
    ])]) }

    static var multiWindow: ClassicUpgradeProfile { ClassicUpgradeProfile(name: "multiWindow", windows: [
        Window(workspaces: (0..<4).map { Workspace(title: "w1 \($0)") }, selected: 3),
        Window(workspaces: (0..<3).map { Workspace(title: "w2 \($0)") }, selected: 1,
               frame: CGRect(x: 200, y: 160, width: 1000, height: 700)),
        // A window saved on a screen that is gone: it still opens, at the default place.
        Window(workspaces: [Workspace(title: "w3 offscreen")], frame: CGRect(x: 90_000, y: 90_000, width: 900, height: 600)),
    ])
    }

    /// Classic before 2026-06: no stableId/workspaceId, groups or panel types.
    static var oldSchema: ClassicUpgradeProfile { ClassicUpgradeProfile(name: "oldSchema", windows: [Window(
        workspaces: [
            Workspace(title: "legacy a", stableID: nil),
            Workspace(title: "legacy b", stableID: nil,
                      layout: .split(vertical: true, ratio: 0.4, .pane([.terminal()]), .pane([.terminal()]))),
            Workspace(title: "legacy c", stableID: nil),
        ])], legacyKeys: true) }

    /// Damage classic could leave: unknown and mistyped fields, a dangling
    /// group, a group without id, a stableId saved twice, a missing folder,
    /// odd names, a Cloud VM and an SSH-less `remote`.
    static var messy: ClassicUpgradeProfile {
        let twice = UUID().uuidString
        return ClassicUpgradeProfile(name: "messy", windows: [Window(
            workspaces: [
                Workspace(title: "unknown fields", raw: ["futureField": ["a": 1], "isMuted": "yes", "hasUnreadIndicator": 3]),
                Workspace(title: "wrong types", raw: ["isPinned": "true", "customColor": 123, "groupId": 7]),
                Workspace(title: "dangling group", group: "G-GONE"),
                Workspace(title: "first of twice", stableID: twice),
                Workspace(title: "second of twice", stableID: twice),
                Workspace(title: "folder gone", folder: "/nonexistent/\(UUID().uuidString)"),
                Workspace(title: "  spaced  "),
                Workspace(title: "emoji 🚀 עברית 日本語"),
                Workspace(title: String(repeating: "long ", count: 400)),
                Workspace(title: "vm", cloudVM: true),
                Workspace(title: "websocket remote", stays: true, raw: ["remote": ["transport": "websocket"]]),
                Workspace(title: "null layout", raw: ["layout": NSNull()]),
                Workspace(title: "empty side", layout: .split(vertical: false, ratio: 0.5, .pane([]), .pane([.terminal()]))),
            ],
            groups: [Group(id: "", name: "no id"), Group(id: "G-OK", name: "fine")], selected: 99)])
    }

    /// Classic at its limits: 4 windows at classic's cap of 128 workspaces
    /// each (`SessionPersistencePolicy.maxWorkspacesPerWindow`), 512 workspaces, 30 groups.
    static var huge: ClassicUpgradeProfile {
        let windows = (0..<4).map { window in
            let groups = (0..<8).map { Group(id: "H-\(window)-\($0)", name: "W\(window) group \($0)", collapsed: $0 % 2 == 0) }
            let workspaces = (0..<128).map { index in
                Workspace(title: "huge \(window)-\(index)", group: index % 3 == 0 ? nil : "H-\(window)-\(index % 8)",
                          pinned: index == 0, color: index % 10 == 0 ? "#00AAFF" : nil,
                          layout: index % 13 == 0 ? .split(vertical: false, ratio: 0.5, .pane([.terminal()]), .pane([.terminal()]))
                                                  : .pane([.terminal()]))
            }
            return Window(workspaces: workspaces, groups: Array(groups.prefix(window == 3 ? 6 : 8)), selected: 64)
        }
        return ClassicUpgradeProfile(name: "huge", windows: windows)
    }

    /// Every profile the simulation runs end to end.
    static var matrix: [ClassicUpgradeProfile] { [fresh, small, manyGroups, nestedSplits, browsersAndViewers, multiWindow, oldSchema, messy] }
}
