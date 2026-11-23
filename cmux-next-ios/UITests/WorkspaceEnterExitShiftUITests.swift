import XCTest

/// Frame-by-frame gate for the workspace push and pop.  The measurement reader
/// is deliberately kept separate from this choreography so the same samples
/// can be compared with a recorded simulator video.
final class WorkspaceEnterExitShiftUITests: XCTestCase {
    private struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAgentKeyboardDown() throws {
        try run(surface: "agent", workspaceID: "ws-cmux", keyboardUp: false)
    }

    @MainActor
    func testAgentKeyboardUp() throws {
        try run(surface: "agent", workspaceID: "ws-cmux", keyboardUp: true)
    }

    @MainActor
    func testTerminalKeyboardDown() throws {
        try run(surface: "terminal", workspaceID: "ws-ios", keyboardUp: false)
    }

    @MainActor
    func testTerminalKeyboardUp() throws {
        try run(surface: "terminal", workspaceID: "ws-ios", keyboardUp: true)
    }

    @MainActor
    func testBrowserKeyboardDown() throws {
        try run(surface: "browser", workspaceID: "ws-blog", keyboardUp: false)
    }

    @MainActor
    func testBrowserKeyboardUp() throws {
        try run(surface: "browser", workspaceID: "ws-blog", keyboardUp: true)
    }

    @MainActor
    private func run(surface: String, workspaceID: String, keyboardUp: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += [
            "-cmuxMobile.setupComplete", "YES",
            "-cmux-mobile-no-restore",
            "-cmux-mobile-tab", "workspaces",
            "-cmux-mobile-workspace-shift-trace"
        ]
        app.launchEnvironment["CMUX_SHIFT_WORKSPACE_ID"] = workspaceID
        app.launch()
        defer { app.terminate() }

        let list = app.collectionViews["workspaces.list"]
        let choose = app.scrollViews["setup.teams.choose"]
        if !list.waitForExistence(timeout: 2), choose.waitForExistence(timeout: 10) {
            let team = app.buttons["Manaflow"].firstMatch
            try require(team.waitForExistence(timeout: 10), "mock team chooser did not show Manaflow")
            team.tap()
        }
        try require(list.waitForExistence(timeout: 30), "the Workspaces list loaded")
        let row = app.buttons["workspace.row.\(workspaceID)"].firstMatch

        if keyboardUp {
            try showListSearch(app, query: query(for: workspaceID), workspaceID: workspaceID)
        } else {
            try require(!app.keyboards.firstMatch.exists, "the list starts with keyboard down")
            try makeRowHittable(row, in: list, workspaceID: workspaceID)
        }

        let trace = try WorkspaceShiftMeasurement(app: app)
        try trace.measure(in: self, surface: surface, direction: "enter", keyboardUp: keyboardUp,
                          workspaceID: workspaceID, action: {
            let target = app.buttons["workspace.row.\(workspaceID)"].firstMatch
            try self.require(target.exists && target.isHittable, "\(workspaceID) row is tappable")
            target.tap()
        }, arrived: {
            try self.require(app.descendants(matching: .any)["workspace.\(workspaceID)"].waitForExistence(timeout: 20),
                             "entered workspace \(workspaceID)")
        })

        if keyboardUp {
            try focusSurface(app, surface: surface)
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                        "\(surface) keyboard is up before exit")
        } else {
            try require(!app.keyboards.firstMatch.exists, "\(surface) starts exit with keyboard down")
        }

        try trace.measure(in: self, surface: surface, direction: "exit", keyboardUp: keyboardUp,
                          workspaceID: workspaceID, action: {
            popFromWorkspace(app)
        }, arrived: {
            try self.require(list.waitForExistence(timeout: 20), "returned to Workspaces list from \(workspaceID)")
            try self.require(!app.descendants(matching: .any)["workspace.\(workspaceID)"].exists, "workspace route popped")
        })
    }

    @MainActor
    private func showListSearch(_ app: XCUIApplication, query: String, workspaceID: String) throws {
        let list = app.collectionViews["workspaces.list"]
        let field = app.searchFields.firstMatch
        // The drawer is tucked under the bar at launch (it exists, not hittable): pull down
        // until it is out, as WorkspacesListUITests does.
        for _ in 0..<4 where !(field.exists && field.isHittable) {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60)))
            _ = field.waitForExistence(timeout: 3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        try require(field.exists && field.isHittable, "Workspaces search field\n\(app.debugDescription)")
        field.tap()
        field.typeText(query)
        try require(app.keyboards.firstMatch.waitForExistence(timeout: 10), "list search keyboard")
        let row = app.buttons["workspace.row.\(workspaceID)"].firstMatch
        try require(row.waitForExistence(timeout: 10) && row.isHittable, "filtered row \(workspaceID) is hittable")
    }

    @MainActor
    private func makeRowHittable(_ row: XCUIElement, in list: XCUIElement, workspaceID: String) throws {
        for _ in 0..<8 {
            if row.exists && row.isHittable { return }
            list.swipeUp()
        }
        try require(row.exists && row.isHittable, "fixture row \(workspaceID) is hittable")
    }

    private func query(for workspaceID: String) -> String {
        switch workspaceID {
        case "ws-cmux": return "cmux"
        case "ws-ios": return "cmux-next-ios"
        default: return "blog"
        }
    }

    @MainActor
    private func focusSurface(_ app: XCUIApplication, surface: String) throws {
        switch surface {
        case "agent":
            let field = app.textViews["chat.composer.field"].firstMatch
            if !field.exists {
                let collapsed = app.buttons["Reply to Claude"].firstMatch
                try require(collapsed.waitForExistence(timeout: 10), "agent composer capsule")
                collapsed.tap()
            }
            try require(field.waitForExistence(timeout: 10), "agent composer field")
            field.tap()
        case "terminal":
            let field = app.textViews["terminal.composer.field"].firstMatch
            if field.waitForExistence(timeout: 10) { field.tap() }
            else {
                let key = app.buttons["terminal.key.keyboard"].firstMatch
                try require(key.waitForExistence(timeout: 10), "terminal keyboard key")
                key.tap()
            }
        case "browser":
            // ws-blog is an offline data: page. Require the real WKWebView's
            // input so this case measures the page/keyboard transition, not
            // only TabsKit's address editor.
            let webView = app.webViews.firstMatch
            try require(webView.waitForExistence(timeout: 20), "browser WKWebView")
            let input = webView.textFields["Page input"].firstMatch
            try require(input.waitForExistence(timeout: 20), "browser WKWebView page input")
            input.tap()
        default:
            throw SetupError(description: "unknown surface \(surface)")
        }
    }

    @MainActor
    private func popFromWorkspace(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.50))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SetupError(description: message) }
    }
}
