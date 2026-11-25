import XCTest

/// The terminal page through a link drop and back, for a clip of the reconnect path
/// (`-cmux-mobile-demo ws-terminal-drop-back`): the rows drawn before the drop stay on screen the
/// whole time, the title pill says the Mac is offline only past the quiet bound, and the page
/// attaches again by itself with no tap.
///
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=TerminalDropAndBackUITests --arg video \
///       --artifact artifacts/ios-sim/evidence.zip
final class TerminalDropAndBackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDropKeepsTheRowsAndComesBackByItself() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", "ws-terminal-drop-back"]
        app.launch()
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        keep(app, "1-attached")

        // Past the quiet bound of the drop the title pill says the Mac is offline ("Mac offline").
        let offline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "offline")).firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 20), "the offline subtitle\n\(app.debugDescription)")
        keep(app, "2-offline-rows-kept")
        XCTAssertTrue(field.exists, "the composer stays while offline")

        // Back by itself: the subtitle goes and output flows again.
        XCTAssertTrue(offline.waitForNonExistence(timeout: 15), "attached again with no tap")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        keep(app, "3-back")
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
