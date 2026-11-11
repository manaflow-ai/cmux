import XCTest

/// Captures for PR #40135 (ui-state-fixes I1-I3): each surface first shows its connecting state,
/// then, after its deadline with nothing cached, its failed state with Retry, in Dark and Light.
/// The frames attached here (about one a second) and the step's simulator video are the evidence;
/// the waits only pace the captures, nothing waits on them for synchronization.
final class UIStateDeadlineCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: I1 Chief

    @MainActor func testChiefConnectFailedDark() throws { try chief(.dark, "dark") }
    @MainActor func testChiefConnectFailedLight() throws { try chief(.light, "light") }

    /// Chief over a conversation backend that never connects (`CMUX_MOBILE_CHIEF_SIM` names a closed
    /// port) and nothing kept: "Connecting…" then, after `ConversationStore.connectDeadline` (15 s),
    /// "Couldn't connect · Retry" in the header and "Couldn't connect" with Retry in the body.
    @MainActor
    private func chief(_ appearance: XCUIDevice.Appearance, _ look: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        // Settings › Appearance for this launch: the system setting alone left the app light.
        app.launchArguments += ["-cmuxMobile.settings.appearance", appearance == .dark ? "dark" : "light"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_CHIEF_SIM"] = "ws://127.0.0.1:9/ws?conversation=direct"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "chief-open"]
        app.launch()
        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        let status = app.descendants(matching: .any)["conversation.header.status"]
        attach(app, "i1-chief-\(look)-00-connecting")
        let failed = app.descendants(matching: .any)["conversation.connectFailed"]
        for frame in 1..<22 {
            pace(1)
            attach(app, String(format: "i1-chief-\(look)-frame-%02d", frame))
            if failed.exists, frame > 2 { break }
        }
        XCTAssertTrue(failed.waitForExistence(timeout: 20), "the body's Couldn't connect\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Couldn't connect"].exists, "Couldn't connect title")
        XCTAssertTrue(app.buttons["conversation.connect.retry"].exists, "Retry button")
        XCTAssertEqual(status.label, "Couldn't connect · Retry", "header status")
        pace(1)
        attach(app, "i1-chief-\(look)-10-failed")
        app.buttons["conversation.connect.retry"].tap()
        pace(0.6)
        attach(app, "i1-chief-\(look)-20-after-retry-connecting")
        XCTAssertEqual(status.label, "Connecting…", "Retry starts connecting again")
        app.terminate()
    }

    // MARK: I2 Feed

    @MainActor func testFeedOfflineDark() throws { try feed(.dark, "dark") }
    @MainActor func testFeedOfflineLight() throws { try feed(.light, "light") }

    /// The Feed with no Mac and nothing kept (`-cmux-mobile-demo feed-connecting`): "Connecting to
    /// your Mac…", then after `FeedStore.connectDeadline` (15 s) "Your Macs are offline" with Retry.
    @MainActor
    private func feed(_ appearance: XCUIDevice.Appearance, _ look: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        // Settings › Appearance for this launch: the system setting alone left the app light.
        app.launchArguments += ["-cmuxMobile.settings.appearance", appearance == .dark ? "dark" : "light"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "feed-connecting"]
        app.launch()
        let connecting = app.descendants(matching: .any)["feed.connecting"]
        XCTAssertTrue(connecting.waitForExistence(timeout: 30), "Connecting to your Mac…\n\(app.debugDescription)")
        attach(app, "i2-feed-\(look)-00-connecting")
        let offline = app.descendants(matching: .any)["feed.offline"]
        for frame in 1..<22 {
            pace(1)
            attach(app, String(format: "i2-feed-\(look)-frame-%02d", frame))
            if offline.exists, frame > 2 { break }
        }
        XCTAssertTrue(offline.waitForExistence(timeout: 20), "Your Macs are offline\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Your Macs are offline"].exists, "offline title")
        pace(1)
        attach(app, "i2-feed-\(look)-10-offline")
        // The offline stack's identifier covers its Retry button's own, so it is found by its label.
        let retry = app.buttons["Retry"].firstMatch
        XCTAssertTrue(retry.exists, "Retry\n\(app.debugDescription)")
        retry.tap()
        pace(0.6)
        attach(app, "i2-feed-\(look)-20-after-retry")
        app.terminate()
    }

    // MARK: I3 Screen Sharing

    @MainActor func testScreenSharingNoAnswerDark() throws { try screenSharing(.dark, "dark") }
    @MainActor func testScreenSharingNoAnswerLight() throws { try screenSharing(.light, "light") }

    /// The real viewer card for a Mac that never answers (`-CmuxMobileScreenSharingConnectDemo`):
    /// "Connecting to Demo Mac…" with a spinner, then after `ScreenSharingViewer.goAheadDeadline`
    /// (30 s) "Couldn't reach Demo Mac" with Try Again.
    @MainActor
    private func screenSharing(_ appearance: XCUIDevice.Appearance, _ look: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        // Settings › Appearance for this launch: the system setting alone left the app light.
        app.launchArguments += ["-cmuxMobile.settings.appearance", appearance == .dark ? "dark" : "light"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileScreenSharingConnectDemo"]
        app.launch()
        let spinner = app.descendants(matching: .any)["screenSharing.progress"]
        XCTAssertTrue(spinner.waitForExistence(timeout: 30), "the connecting card's spinner\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Connecting to Demo Mac…"].exists, "connecting title\n\(app.debugDescription)")
        attach(app, "i3-screen-\(look)-00-connecting")
        let failed = app.staticTexts["Couldn't reach Demo Mac"]
        for frame in 1..<38 {
            pace(1)
            attach(app, String(format: "i3-screen-\(look)-frame-%02d", frame))
            if failed.exists, frame > 2 { break }
        }
        XCTAssertTrue(failed.waitForExistence(timeout: 20), "Couldn't reach Demo Mac\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Try Again"].exists, "Try Again\n\(app.debugDescription)")
        pace(1)
        attach(app, "i3-screen-\(look)-10-failed")
        app.buttons["Try Again"].tap()
        pace(0.8)
        attach(app, "i3-screen-\(look)-20-after-try-again")
        XCTAssertTrue(spinner.waitForExistence(timeout: 5), "Try Again shows the spinner again")
        app.terminate()
    }

    // MARK: Helpers

    /// Paces a capture (a run loop wait, not app synchronization).
    private func pace(_ seconds: TimeInterval) {
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
