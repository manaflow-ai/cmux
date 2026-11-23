import XCTest

/// Leo, 2026-11-23: "i cant easily go back to a workspace with a tap to the top when im in the
/// agent chat gui. it's just a complete softlock unless i swipe or completely tap out of the
/// composer." The Safari bar moved to the top, so from a workspace's composer, keyboard up, one
/// tap on Back reaches the Workspaces list: no swipe, no dismissing the keyboard first.
///
/// On the bottom bar this fails: Back rides the keyboard's top edge, not the top of the screen
/// where Leo taps for it. Each check prints a `CMUX_TOP_BACK` line; every step attaches the screen.
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
                let candidates = app.buttons.matching(identifier: "Back").allElementsBoundByIndex
                print("CMUX_TOP_BACK \(step) candidates: " + candidates.map { "\($0.frame) hittable=\($0.isHittable)" }
                    .joined(separator: " | "))
                // Keyboard down first: Back already sits at the top of the screen.
                let restingBack = app.buttons["Back"].firstMatch
                let restingTop = restingBack.waitForExistence(timeout: 5) && restingBack.isHittable
                    && restingBack.frame.midY < app.frame.height * 0.25
                print("CMUX_TOP_BACK \(step) keyboard-down back=\(restingBack.exists ? "\(restingBack.frame)" : "none") " +
                      "screen=\(app.frame.size): \(restingTop ? "top" : "NOT-AT-TOP")")
                XCTAssertTrue(restingTop, "\(step): keyboard down, Back is not at the top (\(restingBack.frame) on \(app.frame.size))")
                attach(app, "\(step)-keyboard-down")
                // The workspace's composer, whichever kind it opened on: the agent chat's (a
                // collapsed "Reply to ..." capsule first) or the terminal's. No composer is a failure:
                // a skipped step proved nothing on the run before this one.
                guard focusComposer(app) else {
                    XCTFail("\(step): no composer to focus\n\(app.debugDescription)")
                    attach(app, "FAIL-\(step)-no-composer")
                    leave(app)
                    continue
                }
                let keyboard = app.keyboards.firstMatch
                XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "\(step): no keyboard")
                attach(app, "\(step)-keyboard-up")
                let back = app.buttons["Back"].firstMatch
                let above = back.exists && back.isHittable && back.frame.maxY < keyboard.frame.minY
                // "a tap to the top": Back is in the top quarter of the screen, where the thumb
                // reaches for it, not riding the keyboard's top edge.
                let atTop = back.exists && back.frame.midY < app.frame.height * 0.25
                print("CMUX_TOP_BACK \(step) back=\(back.exists ? "\(back.frame)" : "none") keyboard=\(keyboard.frame) " +
                      "screen=\(app.frame.size): \(above ? "above" : "HIDDEN") \(atTop ? "top" : "NOT-AT-TOP")")
                XCTAssertTrue(above, "\(step): Back is not above the keyboard (\(back.frame) vs \(keyboard.frame))")
                XCTAssertTrue(atTop, "\(step): Back is not at the top (\(back.frame) on \(app.frame.size))")
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

    /// Focuses the open workspace's composer; false when it has none.
    private func focusComposer(_ app: XCUIApplication) -> Bool {
        for id in ["chat.composer.field", "terminal.composer.field"] {
            let field = app.textViews[id].firstMatch
            if field.waitForExistence(timeout: 3), field.isHittable { field.tap(); return true }
        }
        let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        if capsule.waitForExistence(timeout: 3), capsule.isHittable {
            capsule.tap()
            let field = app.textViews["chat.composer.field"].firstMatch
            if field.waitForExistence(timeout: 5) { if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }; return true }
        }
        let key = app.buttons["terminal.key.keyboard"].firstMatch
        if key.waitForExistence(timeout: 3), key.isHittable { key.tap(); return true }
        return false
    }
}
