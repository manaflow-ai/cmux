import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// What classic cmux showed in each workspace comes over as it was, end to end on the real daemon
/// (``ClassicUpgradeSimulator``): the tab each pane had selected, its pinned tabs, the pane it focused,
/// markdown and file preview tabs on their files, and the workspace's description, task lane, color (classic's hex, as the
/// palette color the sidebar draws) and the name the person gave it (theirs: the automatic naming leaves it alone).
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeParityTests {
    /// One workspace in two panes. Left: a terminal, a pinned terminal and a page, the first terminal selected.
    /// Right (focused): a markdown file, a picture's preview and a markdown file that is gone, the preview selected.
    private static func session(home: String) -> [String: Any] {
        let ids = (0..<6).map { _ in UUID().uuidString }
        let (terminal, pinned, page, markdown, preview, gone) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        func shell(_ id: String, pinned: Bool) -> [String: Any] {
            ["id": id, "type": "terminal", "isPinned": pinned, "isManuallyUnread": false, "listeningPorts": [Int](),
             "directory": home, "terminal": ["workingDirectory": home]]
        }
        let panels: [[String: Any]] = [
            shell(terminal, pinned: false),
            shell(pinned, pinned: true),
            ["id": page, "type": "browser", "isPinned": false, "browser": ["urlString": "about:blank"]],
            ["id": markdown, "type": "markdown", "isPinned": false, "markdown": ["filePath": "\(home)/notes.md"]],
            ["id": preview, "type": "filePreview", "isPinned": false, "filePreview": ["filePath": "\(home)/shot.png"]],
            ["id": gone, "type": "markdown", "isPinned": false, "markdown": ["filePath": "\(home)/gone.md"]],
        ]
        let workspace: [String: Any] = [
            "stableId": UUID().uuidString, "workspaceId": UUID().uuidString,
            "customTitle": "Parity", "customTitleSource": "user", "processTitle": "~",
            "customDescription": "Draft the release notes", "taskStatusOverride": "review", "taskStatusInferredAtOverride": "todo",
            "currentDirectory": home, "isPinned": false, "customColor": "#7C3AED", "focusedPanelId": preview, "panels": panels,
            "layoutMode": "splits", "logEntries": [Any](), "statusEntries": [Any](),
            "layout": ["type": "split", "split": [
                "orientation": "horizontal", "dividerPosition": 0.5,
                "first": ["type": "pane", "pane": ["panelIds": [terminal, pinned, page], "selectedPanelId": terminal]],
                "second": ["type": "pane", "pane": ["panelIds": [markdown, preview, gone], "selectedPanelId": preview]],
            ]],
        ]
        return ["version": 1, "createdAt": 1_891_000_000.0, "windows": [[
            "windowId": UUID().uuidString,
            "frame": ["x": 120, "y": 120, "width": 1200, "height": 800],
            "sidebar": ["isVisible": true, "width": 240],
            "tabManager": ["selectedWorkspaceIndex": 0, "workspaces": [workspace], "workspaceGroups": [Any]()],
        ]]]
    }

    @Test func eachPaneComesOverAsClassicLeftIt() async throws {
        let mac = try ClassicUpgradeSimulator.Mac()
        try FileManager.default.createDirectory(atPath: mac.home, withIntermediateDirectories: true)
        try Data("# Notes\n\nFrom classic.\n".utf8).write(to: URL(fileURLWithPath: "\(mac.home)/notes.md"))
        // A 1×1 PNG: the browser previews it.
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
            .write(to: URL(fileURLWithPath: "\(mac.home)/shot.png"))
        try JSONSerialization.data(withJSONObject: Self.session(home: mac.home)).write(to: mac.session(), options: .atomic)
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        await sim.settle()

        let store = sim.services.daemon.store
        let workspace = try #require(store.workspaces.first { $0.name == "Parity" }, "\(store.workspaces.map(\.name))")
        #expect(workspace.workspaceDescription == "Draft the release notes")
        #expect(workspace.taskStatus == .review)
        #expect(workspace.nameSource == .user, "\(workspace.nameSource)")
        #expect(workspace.color == "purple", "\(String(describing: workspace.color))")
        let screen = try #require(workspace.screens.first)
        let panes = screen.layout.paneIDs.compactMap { screen.pane($0) }
        try #require(panes.count == 2, "\(panes.map { $0.tabs.map(\.kind) })")
        let (left, right) = (panes[0], panes[1])

        // Pinned first, as classic drew it; the terminal classic selected is selected.
        #expect(left.tabs.map(\.kind) == [.pty, .pty, .browser], "\(left.tabs.map(\.kind))")
        #expect(left.tabs.map(\.pinned) == [true, false, false], "\(left.tabs.map(\.pinned))")
        // The markdown file is its markdown page; the picture keeps its preview; the gone file stays in classic.
        #expect(right.tabs.count == 2, "\(right.tabs.map(\.kind))")
        #expect(right.tabs.first?.page != nil && right.tabs.first?.pageRoute?.hasSuffix("notes.md") == true,
                "\(String(describing: right.tabs.first?.page)) \(String(describing: right.tabs.first?.pageRoute))")
        #expect(right.tabs.last?.kind == .browser && right.tabs.last?.url?.hasSuffix("shot.png") == true,
                "\(String(describing: right.tabs.last?.url))")
        #expect(launch.outcome?.summary.leftTabs == true, "\(String(describing: launch.outcome))")

        let windows = sim.services.windows.controllers
        try #require(!windows.isEmpty)
        for window in windows {
            #expect(window.state.selection.selection(in: left.id) == left.tabs[1].id)
            #expect(window.state.selection.selection(in: right.id) == right.tabs[1].id)
            #expect(window.state.selection.focusedPane(in: workspace.id) == right.id)
        }

        // A relaunch makes nothing more.
        let again = try await sim.relaunch()
        #expect(again.opened.isEmpty, "\(again)")
        await sim.shutdown()
    }
}
