import XCTest

/// A terminal tab nobody looks at stops streaming, and shown again it catches
/// up once (Leo, 2026-11-14: "surely we dont need to stream the f***ing
/// thing"). The list rig's terminals screen (mock data, no Mac) opens two
/// terminal tabs, each running the mock shell's `stream` (a numbered row every
/// 20 ms), and leaves the first on screen. The test then hides both behind the
/// tab grid past the 3 s grace, opens the second tab, then the first, and
/// takes a screenshot at each step: a shown tab's newest row number is where
/// its stream is now (the catch-up), never where it was when it was hidden,
/// and the page shows no "Reattaching" line. Run with `video` for the
/// recording.
final class HiddenTerminalCatchUpUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAHiddenTerminalCatchesUpOnceWhenShown() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "terminals"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "2"
        app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_TERMINAL_VISIBLE"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }

        // The rig opens each tab (2 s apart), starts its stream, then shows the first.
        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 45), "tabs button\n\(app.debugDescription)")
        pause(8)
        attach(app, "1-zsh1-on-screen-streaming")

        // Both tabs hidden behind the grid, well past the 3 s grace.
        tabsButton.tap()
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15), "grid cards\n\(app.debugDescription)")
        pause(8)
        attach(app, "2-grid-both-hidden")

        for (step, title) in [(3, "zsh 2"), (5, "zsh 1")] {
            let card = cards.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), "\(title) card\n\(app.debugDescription)")
            card.tap()
            pause(1)
            attach(app, "\(step)-\(title.replacingOccurrences(of: " ", with: ""))-shown-caught-up")
            XCTAssertFalse(app.descendants(matching: .any)["terminal.connecting"].exists,
                           "\(title): shown again, the page says it is reattaching")
            pause(2)
            attach(app, "\(step + 1)-\(title.replacingOccurrences(of: " ", with: ""))-live-again")
            if step == 3 {
                // Back to the grid: the second tab hides again; the first has been hidden throughout.
                XCTAssertTrue(tabsButton.waitForExistence(timeout: 10), "tabs button")
                tabsButton.tap()
                XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15), "grid cards")
                pause(5)
            }
        }
        print("CMUX_HIDDEN_TERMINAL_CATCHUP done")
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
