import XCTest

/// Leo's 2026-11-22 screenshot: card titles ("…tricting AI agent…", "Explain O1") were legible
/// behind the grid's workspace title. Opens the 29-tab grid (list stress rig, mock data), drags it
/// so a row of cards sits under the title bar, and attaches a screenshot per edge style: the
/// default (opaque to the controls' bottom, then a short fade) and the DEBUG gallery variants
/// (`CMUX_TABS_TITLE_EDGE`). The pictures are the PR's before/after and gallery.
final class TabGridTitleEdgeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTitleEdgeStyles() {
        for style in ["", "hard", "progressiveBlur", "system"] {
            shoot(style: style)
        }
    }

    @MainActor
    private func shoot(style: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "29"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        if !style.isEmpty { app.launchEnvironment["CMUX_TABS_TITLE_EDGE"] = style }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["29 Tabs"].firstMatch.waitForExistence(timeout: 60), "the 29-tab grid\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2.0)
        let name = style.isEmpty ? "default" : style
        attach(app, "\(name)-0-top")
        // A slow drag with a hold: no momentum, so a card row rests under the title bar.
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "\(name)-1-row-under-title")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
