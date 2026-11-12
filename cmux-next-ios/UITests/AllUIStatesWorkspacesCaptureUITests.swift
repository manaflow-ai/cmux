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
        steps([{ openCmux(app) }, { pause(1.5); return tap(app.buttons["Tabs"].firstMatch, "Tabs button") }])
    }

    @MainActor
    func testWorkspacesList() {
        let g = "5 Workspaces list"
        capture([
            Scene(group: g, id: "list", args: Self.list),
            Scene(group: g, id: "list-scrolled", args: Self.list) { app in C.scrollDown(app, times: 2) },
            Scene(group: g, id: "list-compact", args: Self.list + ["-cmuxMobile.settings.compactWorkspaceList", "YES"]),
            Scene(group: g, id: "list-bare-rows", args: Self.list, env: ["CMUX_MOBILE_MOCK_BARE_ROWS": "1"]),
            Scene(group: g, id: "list-200-rows", args: Self.list, env: ["CMUX_MOBILE_LIST_SCREEN": "workspaces", "CMUX_MOBILE_LIST_COUNT": "200", "CMUX_MOBILE_LIST_PASSES": "0"], settle: 4),
            Scene(group: g, id: "offline-fold-expanded", args: Self.list) { app in
                C.steps([{ C.scrollDown(app, times: 2) }, { C.tap(C.any(app, "workspaces.fold.mbp"), "offline Mac fold") }])
            },
            Scene(group: g, id: "offline-mac-alert", args: Self.list) { app in
                C.steps([
                    { C.scrollDown(app, times: 2) },
                    { C.tap(C.any(app, "workspaces.fold.mbp"), "offline Mac fold") },
                    { C.tap(app.buttons["workspace.row.ws-zed"], "ws-zed row") },
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
            Scene(group: g, id: "first-launch-loading", args: ["-cmux-mobile-demo", "retry-first-launch"], settle: 3),
            Scene(group: g, id: "first-launch-offline", args: ["-cmux-mobile-demo", "retry-first-launch-offline"], settle: 3),
            Scene(group: g, id: "first-launch-failed-offline", args: ["-cmux-mobile-demo", "retry-first-launch-failed"], settle: 3),
            Scene(group: g, id: "load-failed-retry", args: ["-cmux-mobile-demo", "retry-workspaces"], settle: 3),
            Scene(group: g, id: "refresh-failed-last-known", args: ["-cmux-mobile-demo", "retry-refresh-failed"], settle: 3),
            Scene(group: g, id: "connect-mac", args: ["-cmux-mobile-demo", "connect-mac"], settle: 2.5),
            Scene(group: g, id: "connect-mac-no-account", args: ["-cmux-mobile-demo", "connect-mac-no-account"], settle: 3),
            Scene(group: g, id: "connect-mac-elsewhere", args: ["-cmux-mobile-demo", "connect-mac-elsewhere"], settle: 0,
                  frames: [("connect-mac-other-team", 3.5), ("switched-team", 8.5)]),
            Scene(group: g, id: "new-workspace-menu", args: Self.list) { app in
                C.longPress(C.any(app, "workspaces.new"), "New Workspace button")
            },
            Scene(group: g, id: "new-workspace-creating", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.tap(C.any(app, "workspaces.new"), "New Workspace button")
            },
            Scene(group: g, id: "workspace-new-demo", args: ["-cmux-mobile-demo", "workspace-new"], settle: 0,
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
            Scene(group: g, id: "agent-tab", args: ["-cmux-mobile-demo", "kbd-tab"], settle: 5),
            Scene(group: g, id: "tabs-grid", args: Self.list) { app in Self.openGrid(app) },
            Scene(group: g, id: "tabs-grid-terminal-cards", args: ["-cmux-mobile-demo", "ws-terminal-card"], settle: 14),
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
                C.steps([{ Self.openCmux(app) }, { C.pause(1.5); return C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") }])
            },
            Scene(group: g, id: "rename-tab-alert", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.pause(1.5); return C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.tap(C.label(app, contains: "Rename Tab"), "Rename Tab…") }])
            },
            Scene(group: g, id: "move-tab-sheet", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.pause(1.5); return C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.tap(C.label(app, contains: "Move Tab to Workspace"), "Move Tab to Workspace…") }])
            },
            Scene(group: g, id: "command-palette", args: Self.list) { app in
                C.steps([{ Self.openCmux(app) }, { C.pause(1.5); return C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.tap(C.label(app, contains: "Command Palette"), "Command Palette…") }])
            },
            Scene(group: g, id: "workspaces-reopen-demo", args: ["-cmux-mobile-demo", "workspaces-reopen"], settle: 0,
                  frames: [("reopened-last-tab", 4.5), ("grid-open", 7.0)]),
            Scene(group: g, id: "workspaces-tour", args: ["-cmux-mobile-demo", "workspaces"], settle: 0,
                  frames: [("chat-sending", 7.0), ("chat-answered", 11.5), ("grid-from-chat", 13.5), ("browser-docs-tab", 21.0)]),
            Scene(group: g, id: "new-claude-workspace-empty", args: ["-cmux-mobile-demo", "kbd-empty"], settle: 6),
            Scene(group: g, id: "new-workspace-creating-pushed", args: ["-cmux-mobile-demo", "kbd-new", "-cmux-mobile-mock-create-delay", "60"], settle: 4),
            Scene(group: g, id: "deep-link-unknown-toast", args: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"],
                  env: ["CMUX_MOBILE_OPEN_URL": "cmux://tab/tab_ffffffffffffffffffffffffffffffff"], settle: 4),
            Scene(group: g, id: "deep-link-tab", args: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"],
                  env: ["CMUX_MOBILE_OPEN_URL": "cmux-dev://workspace/ws_00000000000000000000000000000002"], settle: 5),
        ])
    }
}
