import XCTest

/// A foldable iPhone resizes the app's window live, from a phone's screen to a
/// nearly square one and back (Leo, 2026-11-22: build for the foldable iPhone
/// now, before there is hardware to test on). The fold harness
/// (`-cmux-mobile-fold-sim`, `FoldSimulatorFrame`) does that inside an iPad
/// mini simulator: the foldable's outer screen (466 x 678 pt), then the whole
/// 744 x 1133 window in place of the unfolded one, then the outer screen again,
/// stepping on a timer while the test scrolls the terminal. Run it with
/// `cmux-next-ios-sim.sh test ui=FoldResizeUITests device=iPad,mini,(A17,Pro) video`.
///
/// Folded, one pane; unfolded, the workspace list beside the open workspace
/// (Rust `window_layout`). Across every step the open workspace, its terminal
/// tab and the composer's draft stay. Screenshots at each settled step; the
/// step's video shows the frames in between.
final class FoldResizeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFoldUnfoldFoldKeepsTheWorkspaceAndDraft() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(environment: ["CMUX_MOBILE_FOLD_SIM_SIZES": "466x678,full", "CMUX_MOBILE_FOLD_SIM_INTERVAL": "4"],
                         arguments: ["-cmux-mobile-demo", "ws-terminal-idle"])
        let state = app.staticTexts["debug.fold.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30), "the fold harness\n\(app.debugDescription)")
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the workspace's terminal composer\n\(app.debugDescription)")
        let list = app.otherElements["shell.listColumn"]
        XCTAssertFalse(list.exists, "folded (\(state.label)): one pane")

        let draft = "fold draft kept"
        field.tap()
        field.typeText(draft)
        attach(app, "1-folded-draft")

        // Unfold, then the harness steps on its own (fold at step 2) while the terminal scrolls.
        app.buttons["debug.fold.step"].tap()
        let unfolding = NSPredicate(format: "label BEGINSWITH 'step 1 '")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: unfolding, evaluatedWith: state)], timeout: 10), .completed,
                       "the step button unfolds (\(state.label))\n\(app.debugDescription)")
        var seen: Set<Int> = []
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !seen.contains(2) {
            let step = Self.step(state.label)
            if let step, !seen.contains(step), step >= 1 {
                // Let the 0.6 s resize settle, then check and capture.
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                let unfolded = step % 2 == 1
                XCTAssertEqual(list.exists, unfolded, "step \(step) (\(state.label)): list column\n\(app.debugDescription)")
                XCTAssertTrue(field.exists, "step \(step): the workspace stays open")
                XCTAssertEqual(field.value as? String, draft, "step \(step): the draft stays")
                if unfolded {
                    XCTAssertTrue(app.buttons["workspace.row.ws-cmux"].exists, "step \(step): the list shows the workspaces")
                }
                attach(app, unfolded ? "2-unfolded-two-pane" : "3-folded-again")
                seen.insert(step)
            }
            // Scroll the terminal back and forth: a resize may land mid-scroll.
            let terminal = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45))
            terminal.press(forDuration: 0.05, thenDragTo: terminal.withOffset(CGVector(dx: 0, dy: 160)))
        }
        XCTAssertTrue(seen.isSuperset(of: [1, 2]), "unfolded and folded again (\(seen.sorted()), \(state.label))")
        print("fold resize: steps \(seen.sorted()) draft=\(field.value ?? "nil")")
    }

    /// The unfolded two-pane layout's gallery: Workspaces with nothing open and
    /// with a workspace open, Home, the same in dark mode, and landscape.
    @MainActor
    func testUnfoldedTwoPaneGallery() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(environment: ["CMUX_MOBILE_FOLD_SIM_SIZES": "full"],
                         arguments: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"])
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        XCTAssertTrue(app.otherElements["shell.listColumn"].exists, "unfolded: the list column")
        XCTAssertTrue(app.otherElements["shell.detailPlaceholder"].exists || app.staticTexts["Pick a workspace"].exists,
                      "nothing open yet: the placeholder")
        attach(app, "gallery-1-workspaces-empty")

        row.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(row.exists, "the list stays beside the open workspace")
        attach(app, "gallery-2-workspace-open")

        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = appearance == .dark ? .light : .dark
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, appearance == .dark ? "gallery-3-workspace-open-light" : "gallery-3-workspace-open-dark")
        XCUIDevice.shared.appearance = appearance

        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(app.otherElements["shell.listColumn"].exists, "landscape: still two panes")
        attach(app, "gallery-4-workspace-open-landscape")
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        // An open workspace hides the tab bar (ShellModel.showsTabBar, the phone's rule, kept as is),
        // so Home opens from a fresh launch.
        app.terminate()
        let homeApp = launch(environment: ["CMUX_MOBILE_FOLD_SIM_SIZES": "full"],
                             arguments: ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"])
        if homeApp.scrollViews["setup.teams.choose"].waitForExistence(timeout: 10) { homeApp.buttons["Manaflow"].tap() }
        XCTAssertTrue(homeApp.otherElements["shell.listColumn"].waitForExistence(timeout: 30),
                      "Home unfolded: the chats column\n\(homeApp.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(homeApp, "gallery-5-home")
    }

    @MainActor
    private func launch(environment: [String: String], arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-fold-sim"] + arguments
        app.launch()
        return app
    }

    private static func step(_ label: String) -> Int? {
        let parts = label.split(separator: " ")
        guard parts.count >= 2, parts[0] == "step" else { return nil }
        return Int(parts[1])
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
