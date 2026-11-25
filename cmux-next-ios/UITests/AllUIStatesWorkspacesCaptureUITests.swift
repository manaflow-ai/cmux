import XCTest

/// All-UI-states capture, part 3: the Workspaces list (launch, empty, error,
/// offline states, menus, dialogs) and a workspace's page (tabs grid, menus,
/// sheets, toasts). See `UIStateCapture.swift`.
final class AllUIStatesWorkspacesCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let list = ["-cmux-mobile-tab", "workspaces"]

    @MainActor
    private static func openCmux(_ app: XCUIApplication) -> String? {
        tap(app.buttons["workspace.row.ws-cmux"], "ws-cmux row")
    }

    @MainActor
    private static func openGrid(_ app: XCUIApplication) -> String? {
        steps([{ openCmux(app) }, { tap(app.buttons["Tabs"].firstMatch, "Tabs button") }])
    }

    @MainActor
    func testWorkspacesList() {
        let g = "5 Workspaces list"
        capture([
            Scene(group: g, id: "list", args: Self.list),
            Scene(group: g, id: "list-scrolled", args: Self.list) { app in C.scrollDown(app, times: 2) },
            Scene(group: g, id: "list-compact", args: Self.list + ["-cmuxMobile.settings.compactWorkspaceList", "YES"]),
            Scene(group: g, id: "list-bare-rows", args: Self.list, env: ["CMUX_MOBILE_MOCK_BARE_ROWS": "1"]),
            Scene(group: g, id: "list-200-rows", args: Self.list, env: ["CMUX_MOBILE_LIST_SCREEN": "workspaces", "CMUX_MOBILE_LIST_COUNT": "200", "CMUX_MOBILE_LIST_PASSES": "0"]),
            Scene(group: g, id: "offline-fold-expanded", args: Self.list) { app in
                C.steps([{ C.scrollDown(app, times: 2) }, { C.tap(C.any(app, "workspaces.fold.mbp"), "offline Mac fold") }])
            },
            Scene(group: g, id: "offline-mac-alert", args: Self.list) { app in
                C.steps([
                    { C.scrollDown(app, times: 2) },
                    { C.tap(C.any(app, "workspaces.fold.mbp"), "offline Mac fold") },
                    // The opened rows start under the tab bar: bring them up before the tap.
                    { C.scrollDown(app, times: 2) },
                    { C.tap(app.buttons["workspace.row.ws-zed"], "ws-zed row") },
                    { app.alerts.firstMatch.waitForExistence(timeout: 5) ? nil : "no offline alert" },
                ])
            },
            Scene(group: g, id: "filter-menu", args: Self.list) { app in C.tap(C.any(app, "workspaces.filter"), "filter menu") },
            Scene(group: g, id: "search", args: Self.list) { app in
                app.swipeDown()
                return C.steps([{ C.showKeyboard(app, field: app.searchFields.firstMatch, "search field") }, { app.typeText("cmux"); return nil }])
            },
            Scene(group: g, id: "search-no-results", args: Self.list) { app in
                app.swipeDown()
                return C.steps([{ C.showKeyboard(app, field: app.searchFields.firstMatch, "search field") }, { app.typeText("zzqqxx"); return nil }])
            },
            Scene(group: g, id: "first-launch-loading", args: ["-cmux-mobile-demo", "retry-first-launch"]),
            Scene(group: g, id: "first-launch-offline", args: ["-cmux-mobile-demo", "retry-first-launch-offline"]),
            Scene(group: g, id: "first-launch-failed-offline", args: ["-cmux-mobile-demo", "retry-first-launch-failed"]),
            Scene(group: g, id: "load-failed-retry", args: ["-cmux-mobile-demo", "retry-workspaces"]),
            Scene(group: g, id: "refresh-failed-last-known", args: ["-cmux-mobile-demo", "retry-refresh-failed"]),
            // keep: the connect-mac demo's first step; it moves on at about 6 s.
            Scene(group: g, id: "connect-mac", args: ["-cmux-mobile-demo", "connect-mac"], ready: .clock(2.5)),
            Scene(group: g, id: "connect-mac-no-account", args: ["-cmux-mobile-demo", "connect-mac-no-account"]),
            Scene(group: g, id: "connect-mac-elsewhere", args: ["-cmux-mobile-demo", "connect-mac-elsewhere"],
                  frames: [("connect-mac-other-team", 3.5), ("switched-team", 8.5)]),
            Scene(group: g, id: "new-workspace-menu", args: Self.list) { app in
                C.longPress(C.any(app, "workspaces.new"), "New Workspace button")
            },
            // Its submenus (2026-11-18 reorganize): each folder list once, behind one row.
            Scene(group: g, id: "new-workspace-menu-live-mac", args: Self.list + ["-cmux-mobile-agent-chats"]) { app in
                C.longPress(C.any(app, "workspaces.new"), "New Workspace button")
            },
            Scene(group: g, id: "new-workspace-menu-agent-chat", args: Self.list + ["-cmux-mobile-agent-chats"]) { app in
                C.steps([
                    { C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                    { C.tap(C.any(app, "workspaces.newAgentChatOn"), "New Agent Chat") },
                ])
            },
            Scene(group: g, id: "new-workspace-menu-open-recent", args: Self.list) { app in
                C.steps([
                    { C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                    { C.tap(C.any(app, "workspaces.openRecent"), "Open Recent") },
                ])
            },
            Scene(group: g, id: "new-workspace-menu-agent-workspace", args: Self.list) { app in
                C.steps([
                    { C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                    { C.tap(C.any(app, "workspaces.newAgentWorkspace"), "New Agent Workspace") },
                ])
            },
            Scene(group: g, id: "new-workspace-creating", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.tap(C.any(app, "workspaces.new"), "New Workspace button")
            },
            Scene(group: g, id: "workspace-new-demo", args: ["-cmux-mobile-demo", "workspace-new"],
                  frames: [("new-workspace-pushed", 4.5), ("new-menu-held", 8.5), ("refused-toast", 22.5)]),
            Scene(group: g, id: "open-folder-alert", args: Self.list) { app in
                C.steps([
                    { C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                    { C.tap(C.any(app, "workspaces.openFolder"), "Open Folder…") },
                ])
            },
            Scene(group: g, id: "new-group-alert", args: Self.list) { app in
                C.steps([
                    { C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                    { C.tap(C.any(app, "workspaces.newGroup"), "New Workspace Group…") },
                ])
            },
            Scene(group: g, id: "row-context-menu", args: Self.list) { app in C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
            Scene(group: g, id: "row-swipe-actions", args: Self.list) { app in C.swipeLeft(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
            Scene(group: g, id: "rename-alert", args: Self.list) { app in
                C.steps([{ C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") }, { C.tap(app.buttons["Rename"].firstMatch, "Rename") }])
            },
            Scene(group: g, id: "close-confirm", args: Self.list) { app in
                C.steps([{ C.swipeLeft(app.buttons["workspace.row.ws-web"], "ws-web row") }, { C.tap(app.buttons["Close"].firstMatch, "Close") }])
            },
            Scene(group: g, id: "close-others-confirm", args: Self.list) { app in
                C.steps([
                    { C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
                    { C.scrollDown(app, times: 2) },
                    { C.tap(app.buttons["Close"].firstMatch, "Close folder") },
                    { C.tap(C.label(app, contains: "Close Other"), "Close Other Workspaces") },
                ])
            },
            Scene(group: g, id: "icon-picker", args: Self.list) { app in
                C.steps([{ C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") }, { C.scrollDown(app) }, { C.tap(app.buttons["Appearance"].firstMatch, "Appearance") }, { C.tap(C.label(app, contains: "Set Icon"), "Set Icon…") }])
            },
            Scene(group: g, id: "move-to-new-group", args: Self.list) { app in
                C.steps([
                    { C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
                    { C.scrollDown(app, times: 2) },
                    { C.tap(app.buttons["Group"].firstMatch, "Group folder") },
                    { C.tap(C.label(app, contains: "Move Workspace to Group"), "Move Workspace to Group…") },
                ])
            },
            Scene(group: g, id: "appearance-submenu", args: Self.list) { app in
                C.steps([{ C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") }, { C.scrollDown(app) }, { C.tap(app.buttons["Appearance"].firstMatch, "Appearance") }])
            },
            // The filter and grouping persist across launches: these run last.
            Scene(group: g, id: "filtered-to-mac", args: Self.list) { app in
                C.steps([
                    { C.tap(C.any(app, "workspaces.filter"), "filter menu") },
                    { C.tap(C.label(app, contains: "Mac Studio"), "Mac Studio filter") },
                ])
            },
            Scene(group: g, id: "filtered-offline-mac", args: Self.list) { app in
                C.steps([
                    { C.tap(C.any(app, "workspaces.filter"), "filter menu") },
                    { C.tap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'MacBook Pro'")).firstMatch, "MacBook Pro filter") },
                ])
            },
            Scene(group: g, id: "grouped-by-folder", args: Self.list) { app in
                C.steps([
                    { C.tap(C.any(app, "workspaces.filter"), "filter menu") },
                    { C.tap(C.label(app, contains: "Folder"), "Group by Folder") },
                ])
            },
        ])
    }

    @MainActor
    func testWorkspacePage() {
        let g = "6 Workspace page and tabs"
        capture([
            Scene(group: g, id: "agent-tab", args: ["-cmux-mobile-demo", "kbd-tab"]),
            Scene(group: g, id: "tabs-grid", args: Self.list) { app in Self.openGrid(app) },
            // keep: a moment inside the ws-terminal-card demo, which runs about 16 s.
            Scene(group: g, id: "tabs-grid-terminal-cards", args: ["-cmux-mobile-demo", "ws-terminal-card"], ready: .clock(14)),
            Scene(group: g, id: "card-context-menu", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.longPress(app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'")).firstMatch, "a tab card") }])
            },
            Scene(group: g, id: "grid-more-menu", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.tap(app.buttons["More"].firstMatch, "grid More") }])
            },
            Scene(group: g, id: "grid-select-mode", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.longPress(app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'")).firstMatch, "a tab card") }, { C.tap(C.label(app, contains: "Select Tabs"), "Select Tabs") }])
            },
            Scene(group: g, id: "close-all-confirm", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.tap(app.buttons["More"].firstMatch, "grid More") }, { C.tap(C.label(app, contains: "Close All"), "Close All Tabs") }])
            },
            Scene(group: g, id: "new-tab-menu", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.tap(app.buttons["New"].firstMatch, "New") }])
            },
            Scene(group: g, id: "agent-chooser-sheet", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.tap(app.buttons["New"].firstMatch, "New") }, { C.tap(C.label(app, contains: "New Agent Chat With"), "New Agent Chat With…") }])
            },
            Scene(group: g, id: "screen-sharing-sheet", args: Self.list) { app in
                C.steps([{ Self.openGrid(app) }, { C.tap(app.buttons["New"].firstMatch, "New") }, { C.tap(app.buttons["Screen Sharing"].firstMatch, "Screen Sharing") }])
            },
            Scene(group: g, id: "refused-tab-toast", args: Self.list + ["-cmux-mobile-toast-demo"]) { app in Self.openCmux(app) },
            Scene(group: g, id: "page-menu", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") }])
            },
            Scene(group: g, id: "rename-tab-alert", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.tap(C.label(app, contains: "Rename Tab"), "Rename Tab…") }])
            },
            Scene(group: g, id: "move-tab-sheet", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.tap(C.label(app, contains: "Move Tab to Workspace"), "Move Tab to Workspace…") }])
            },
            Scene(group: g, id: "command-palette", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.tap(C.label(app, contains: "Command Palette"), "Command Palette…") }])
            },
            Scene(group: g, id: "workspaces-reopen-demo", args: ["-cmux-mobile-demo", "workspaces-reopen"],
                  frames: [("reopened-last-tab", 4.5), ("grid-open", 7.0)]),
            Scene(group: g, id: "workspaces-tour", args: ["-cmux-mobile-demo", "workspaces"],
                  frames: [("chat-sending", 7.0), ("chat-answered", 11.5), ("grid-from-chat", 13.5), ("browser-docs-tab", 21.0)]),
            Scene(group: g, id: "new-claude-workspace-empty", args: ["-cmux-mobile-demo", "kbd-empty"]),
            Scene(group: g, id: "new-workspace-creating-pushed", args: ["-cmux-mobile-demo", "kbd-new", "-cmux-mobile-mock-create-delay", "60"]),
            // keep: the toast shows for a while then goes; no marker for its moment.
            Scene(group: g, id: "deep-link-unknown-toast", args: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"],
                  env: ["CMUX_MOBILE_OPEN_URL": "cmux://tab/tab_ffffffffffffffffffffffffffffffff"], ready: .clock(4)),
            // keep: the deep link opens on the app's launch clock, with no marker.
            Scene(group: g, id: "deep-link-tab", args: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"],
                  env: ["CMUX_MOBILE_OPEN_URL": "cmux-dev://workspace/ws_00000000000000000000000000000002"], ready: .clock(5)),
        ])
    }
}
