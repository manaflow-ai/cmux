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

    /// The call screen is up, naming `name` (its elements all carry the screen's identifier,
    /// `chief.call`; the name is one of its texts).
    private func callNames(_ app: XCUIApplication, _ name: String) -> Bool {
        let minimize = app.buttons["Minimize Call"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 15), "the call screen shows\n\(app.debugDescription)")
        app.tap()  // lets the interruption monitor answer the microphone prompt
        return callText(app, name).waitForExistence(timeout: 5)
    }

    private func callText(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "chief.call", label)).firstMatch
    }

    @MainActor
    func testCallFromTheMacChiefsInfoCallsTheMacChiefNotTheCloudChief() {
        let app = launch("call-scope")
        defer { app.terminate() }
        let call = app.buttons["chief.settings.call"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 30), "the Mac Chief's info page\n\(app.debugDescription)")
        shot(app, "call-scope-1-mac-chief-info")
        call.tap()
        let named = callNames(app, "Chief")
        shot(app, "call-scope-2-mac-chief-call")
        XCTAssertFalse(callText(app, "Atlas").exists, "the Mac Chief's Call reached the Cloud Chief, Atlas\n\(app.debugDescription)")
        XCTAssertTrue(named, "the call is to the Mac Chief\n\(app.debugDescription)")
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
        let named = callNames(app, "Atlas")
        shot(app, "call-scope-4-cloud-chief-call")
        XCTAssertTrue(named, "the call is to the Cloud Chief, Atlas\n\(app.debugDescription)")
    }
}
