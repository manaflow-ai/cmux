import XCTest

/// Leo, 2026-11-23: "on terminal correctness, why do we not have a horizontal
/// mode? this is glaringly obvious [and] should've been done from day 1 of
/// making the app." The resize demo (`-CmuxMobileResizeDemo`: the real
/// terminal page and `DaemonTerminalSession` against a scripted Mac) is turned
/// sideways: the page turns with the phone, its grid takes the wider screen's
/// columns, and the Mac is asked for that grid. Turned back, the portrait grid
/// is asked for again. Screenshots at each orientation.
final class TerminalLandscapeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTheTerminalTurnsSidewaysAndTheMacGetsTheWiderGrid() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileResizeDemo"]
        app.launch()

        let step = app.staticTexts["debug.resize-demo"]
        let claim = app.staticTexts["debug.resize-demo.claim"]
        XCTAssertTrue(step.waitForExistence(timeout: 30), "the resize demo's step label\n\(app.debugDescription)")
        XCTAssertTrue(waitFor(30) { step.label == "phone" }, "the demo attached (\(step.label))")
        let portrait = try XCTUnwrap(grid(claim.label), "the phone claimed a grid (\(claim.label))")
        attach(app, "1-portrait-\(portrait.columns)x\(portrait.rows)")

        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = waitFor(10) { (self.grid(claim.label)?.columns ?? 0) > portrait.columns }
        let landscape = grid(claim.label)
        attach(app, "2-landscape-\(claim.label)")
        XCTAssertTrue(turned, "turned sideways, the Mac is asked for a wider grid than portrait's \(portrait.columns)x\(portrait.rows) (asked \(claim.label))")
        if let landscape {
            XCTAssertLessThan(landscape.rows, portrait.rows, "a sideways grid has fewer rows (\(claim.label))")
        }

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitFor(10) { self.grid(claim.label)?.columns == portrait.columns },
                      "turned back, the portrait grid is asked for again (asked \(claim.label))")
        attach(app, "3-portrait-again-\(claim.label)")
    }

    private func grid(_ label: String) -> (columns: Int, rows: Int)? {
        let parts = label.split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    @MainActor
    private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
