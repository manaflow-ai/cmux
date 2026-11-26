import XCTest

/// Site monograms on tab cards (taste prototype, Settings → Advanced, off by default): with the
/// setting on, a browser card with no picture yet shows its site's letter instead of the bare page.
/// Mock data: workspace `ws-cmux`'s Swift docs tab (developer.apple.com) has no picture. Run with
/// `cmux-next-ios-sim.sh test ui=TabCardMonogramUITests video` for the PR's clip.
final class TabCardMonogramUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// On: the Swift docs card draws the monogram.
    @MainActor
    func testGridShowsSiteMonogramWhenOn() throws {
        let probe = openGrid(monograms: true)
        expectFace("monogram", probe)
        // Hold on the grid so the clip shows it.
        Thread.sleep(forTimeInterval: 3)
        let shot = XCTAttachment(screenshot: XCUIApplication().screenshot())
        shot.name = "grid-monogram"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Off (the default): the same card shows the bare page (no glyph), so the monogram is the setting's alone.
    @MainActor
    func testGridShowsBarePageWhenOff() throws {
        expectFace("nothing", openGrid(monograms: false))
    }

    /// Launches on mock data with the setting as given and opens `ws-cmux`'s tab grid; returns the
    /// card face probe (`TabCardFaceProbe`).
    @MainActor
    private func openGrid(monograms: Bool) -> XCUIElement {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux-mobile-card-face-probe",
                                // a plist Bool, as @AppStorage reads it
                                "-cmuxMobile.settings.tabCardMonograms", monograms ? "<true/>" : "<false/>"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabsButton.tap()

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Swift docs' AND label ENDSWITH ', tab'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the browser card\n\(app.debugDescription)")
        return app.staticTexts["tabgrid.cardfaces.probe"].firstMatch
    }

    /// The Swift docs card (`t-docs`) draws `face` now.
    private func expectFace(_ face: String, _ probe: XCUIElement) {
        let now = NSPredicate(format: "value MATCHES %@", ".*\\bt-docs=[a-zA-Z]+>\(face)\\b.*")
        let drew = XCTNSPredicateExpectation(predicate: now, object: probe)
        XCTAssertEqual(XCTWaiter().wait(for: [drew], timeout: 15), .completed,
                       "t-docs should draw \(face): \((probe.value as? String) ?? "no probe")")
    }
}
