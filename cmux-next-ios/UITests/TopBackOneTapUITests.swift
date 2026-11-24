import XCTest

/// Leo, 2026-11-23: "i cant easily go back to a workspace with a tap to the top when im in the
/// agent chat gui. it's just a complete softlock unless i swipe or completely tap out of the
/// composer." The Safari bar moved to the top, so from a workspace's composer, keyboard up, one
/// tap on Back reaches the Workspaces list: no swipe, no dismissing the keyboard first.
///
/// On the bottom bar this fails: Back is under the keyboard (not above it, so the tap lands on
/// the keyboard). Each check prints a `CMUX_TOP_BACK` line; every step attaches the screen.
final class TopBackOneTapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        return app
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Every mock workspace (agent chat, terminal, browser tabs), repeated: one tap on the top
    /// Back with the composer focused lands on Workspaces.
    @MainActor
    func testOneTapBackWithTheKeyboardUp() {
        let app = launch()
        var taps: [String: Int] = [:]
        for round in 1...2 {
            for workspace in ["ws-cmux", "ws-web", "ws-ios"] {
                let step = "r\(round)-\(workspace)"
                let row = app.buttons["workspace.row.\(workspace)"]
                XCTAssertTrue(row.waitForExistence(timeout: 15), "\(step): row")
                row.tap()
                let page = app.descendants(matching: .any)["workspace.\(workspace)"]
                XCTAssertTrue(page.waitForExistence(timeout: 15), "\(step): workspace not shown")
                let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
                guard field.waitForExistence(timeout: 10), field.isHittable else {
                    print("CMUX_TOP_BACK \(step): SKIPPED (no composer field)")
                    attach(app, "SKIP-\(step)")
                    leave(app)
                    continue
                }
                field.tap()
                let keyboard = app.keyboards.firstMatch
                XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "\(step): no keyboard")
                attach(app, "\(step)-keyboard-up")
                let back = app.buttons["Back"].firstMatch
                let above = back.exists && back.isHittable && back.frame.maxY < keyboard.frame.minY
                print("CMUX_TOP_BACK \(step) back=\(back.exists ? "\(back.frame)" : "none") keyboard=\(keyboard.frame): \(above ? "above" : "HIDDEN")")
                XCTAssertTrue(above, "\(step): Back is not above the keyboard (\(back.frame) vs \(keyboard.frame))")
                // One tap, wherever Back is: a hidden Back's tap lands on the keyboard and stays put.
                if back.exists { back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                let home = app.buttons["workspace.row.\(workspace)"].waitForExistence(timeout: 8)
                    && !app.descendants(matching: .any)["workspace.\(workspace)"].exists
                print("CMUX_TOP_BACK \(step) one tap: \(home ? "workspaces" : "STILL IN WORKSPACE")")
                XCTAssertTrue(home, "\(step): one tap on Back did not reach Workspaces")
                attach(app, home ? "\(step)-workspaces" : "FAIL-\(step)")
                taps[workspace, default: 0] += home ? 1 : 0
                if !home { leave(app) }
            }
        }
        print("CMUX_TOP_BACK summary \(taps.sorted { $0.key < $1.key })")
    }

    /// Recovery after a failed step, so the next workspace is still tested.
    @MainActor
    func leave(_ app: XCUIApplication) {
        app.swipeDown(velocity: .fast)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
    }
}
