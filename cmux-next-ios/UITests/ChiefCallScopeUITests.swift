import XCTest

/// A Chief call is to the Chief called, and only it (Aziz 2026-11-05: "the chief I called was
/// only able to see the cloud chief"). A Cloud Chief, Atlas, is the default Chief here; before
/// the fix every call went to it, whichever Chief's Call was tapped. The Realtime connection is
/// the DEBUG scripted link (CMUX_MOBILE_CALL_DEMO=hold: no key, no network).
final class ChiefCallScopeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ demo: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_CALL_DEMO"] = "hold"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        app.launch()
        // The microphone prompt the call asks for: allow it so the scripted call runs.
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func callName(_ app: XCUIApplication) -> String {
        let name = app.staticTexts["chief.call.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 15), "the call screen shows\n\(app.debugDescription)")
        app.tap()  // lets the interruption monitor answer the microphone prompt
        return name.label
    }

    @MainActor
    func testCallFromTheMacChiefsInfoCallsTheMacChiefNotTheCloudChief() {
        let app = launch("call-scope")
        defer { app.terminate() }
        let call = app.buttons["chief.settings.call"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 30), "the Mac Chief's info page\n\(app.debugDescription)")
        shot(app, "call-scope-1-mac-chief-info")
        call.tap()
        let name = callName(app)
        shot(app, "call-scope-2-mac-chief-call")
        XCTAssertNotEqual(name, "Atlas", "the Mac Chief's Call reached the Cloud Chief")
        XCTAssertEqual(name, "Chief")
    }

    @MainActor
    func testCallFromTheCloudChiefsTileCallsTheCloudChief() {
        let app = launch("call-scope-home")
        defer { app.terminate() }
        let tile = app.descendants(matching: .any)["home.chief"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "Home shows the Cloud Chief\n\(app.debugDescription)")
        shot(app, "call-scope-3-home")
        tile.press(forDuration: 1.2)
        let call = app.buttons["home.chief.call"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 10), "the tile's menu has Call Chief\n\(app.debugDescription)")
        call.tap()
        let name = callName(app)
        shot(app, "call-scope-4-cloud-chief-call")
        XCTAssertEqual(name, "Atlas")
    }
}
