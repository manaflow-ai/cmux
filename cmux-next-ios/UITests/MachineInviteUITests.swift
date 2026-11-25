import XCTest

/// The Mac's invite QR for a new machine (Pair Another Machine…, `https://cmux.com/pair?i=…`)
/// opens the phone's Pair Another Machine sheet with the code filled in. The launch is handed the
/// URL as the system opens one (`CMUX_MOBILE_OPEN_URL`, DEBUG only): until cmux.com's site
/// association claims `/pair`, `simctl openurl` of that link lands in Safari.
final class MachineInviteUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testInviteLinkOpensPairAnotherMachineWithTheCode() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // Lowercase with a look-alike: the sheet shows the code as the Mac does.
        app.launchEnvironment["CMUX_MOBILE_OPEN_URL"] = "https://cmux.com/pair?i=abcde-i2345"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        let start = Date()
        app.launch()
        let code = app.staticTexts["machineInvite.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 30), "invite sheet\n\(app.debugDescription)")
        let opened = Date().timeIntervalSince(start)
        print("CMUX_MOBILE_UI_TIMING machine-invite-sheet launch-to-code \(Int(opened * 1000)) ms")
        XCTAssertEqual(code.label, "ABCDE-12345")
        XCTAssertTrue(app.staticTexts["machineInvite.line"].exists, "command")
        XCTAssertEqual(app.staticTexts["machineInvite.line"].label, "cmux pair ABCDE-12345")
        attach(app, "01-invite-sheet")

        let copy = app.buttons["machineInvite.copyLine"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Command")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5), "Copied\n\(app.debugDescription)")
        attach(app, "02-command-copied")

        app.buttons["machineInvite.done"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: code)
        wait(for: [gone], timeout: 10)
        attach(app, "03-closed")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("CMUX_MOBILE_UI_STEP \(name)")
    }
}
