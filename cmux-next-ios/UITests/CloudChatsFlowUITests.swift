import XCTest

/// "Open a running Cloud chat from iPhone", walked on the real screens with
/// the app's mock data (CMUX_MOBILE_MOCK_AUTH, no live Mac link): Home's
/// Cloud chats button, the sheet's first state, its recovery action, and the
/// Cloud machine's connect states as `-cmux-mobile-recovery-gallery cloud`
/// draws them. Each step prints one `ERGO` line (kind, what is on screen,
/// whether it names a reason and an ETA, seconds since the tap) for the
/// ergonomics count; the fleet step records the screen as it runs.
final class CloudChatsFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var started = Date()

    private func ergo(_ kind: String, _ what: String, reason: Bool? = nil, eta: Bool? = nil) {
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        var line = "ERGO kind=\(kind) t=\(seconds)s what=\"\(what)\""
        if let reason { line += " reason=\(reason ? "yes" : "no")" }
        if let eta { line += " eta=\(eta ? "yes" : "no")" }
        print(line)
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Home → Cloud chats with no Mac link: what the sheet shows, and where its one action leads.
    @MainActor
    func testCloudChatsFromHomeWithoutAMacLink() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "shell\n\(app.debugDescription)")
        shot(app, "01-home")

        let open = app.buttons["Cloud chats"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Home's Cloud chats button\n\(app.debugDescription)")
        started = Date()
        open.tap()
        ergo("tap", "Home: Cloud chats")
        XCTAssertTrue(app.navigationBars["Cloud chats"].waitForExistence(timeout: 10), "sheet\n\(app.debugDescription)")

        let loading = text(app, containing: "Loading Cloud chats")
        if loading.exists { ergo("wait", "Loading Cloud chats…", reason: true, eta: false) }

        // The sheet's first settled state with no live Mac link.
        let before = text(app, containing: "Connect a Mac to see its Cloud chats")
        let after = app.buttons["cloudChats.connectMac"]
        // Whichever build this is: wait for either state, not one then the other (the seconds count).
        let deadline = Date().addingTimeInterval(20)
        while !before.exists, !after.exists, Date() < deadline { _ = after.waitForExistence(timeout: 0.25) }
        XCTAssertTrue(before.exists || after.exists, "no-link state\n\(app.debugDescription)")
        shot(app, "02-no-mac-link")

        if after.exists {
            ergo("state", "Connect your Mac (with Connect a Mac)", reason: true)
            started = Date()
            after.tap()
            ergo("tap", "Connect a Mac")
            // The existing pairing page: Settings → Devices, its Macs and Scan QR on your Mac.
            let devices = app.navigationBars["Devices"]
            XCTAssertTrue(devices.waitForExistence(timeout: 10), "Settings → Devices\n\(app.debugDescription)")
            XCTAssertFalse(app.navigationBars["Cloud chats"].exists, "the sheet closed")
            ergo("state", "Settings → Devices (pair a Mac)")
            shot(app, "03-devices")
        } else {
            // Before: the line names no next step; the sheet's only actions are Retry, Refresh and Done.
            let retry = app.buttons["Retry"].firstMatch
            XCTAssertTrue(retry.exists, "Retry\n\(app.debugDescription)")
            ergo("deadend", "Connect a Mac to see its Cloud chats. (Retry only)", reason: true)
            started = Date()
            retry.tap()
            ergo("tap", "Retry")
            XCTAssertTrue(before.waitForExistence(timeout: 20), "Retry leads back\n\(app.debugDescription)")
            ergo("deadend", "Connect a Mac to see its Cloud chats. (again after Retry)", reason: true)
            shot(app, "03-retry-same")
            XCTFail("Dead end: \"Connect a Mac to see its Cloud chats.\" has no action that connects a Mac")
        }
    }

    /// A Cloud machine's connect states, drawn by the production views
    /// (`-cmux-mobile-recovery-gallery cloud`): the wait and its timeout.
    @MainActor
    func testCloudMachineConnectStates() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "cloud"]
        app.launch()
        defer { app.terminate() }
        started = Date()
        let wait = app.descendants(matching: .any)["cloudChats.connecting"].firstMatch
        guard wait.waitForExistence(timeout: 30) else {
            // Before: the gallery has no Cloud scene; the screen reads "Connecting…" alone.
            ergo("wait", "Connecting… (CloudMachineChatsScreen)", reason: false, eta: false)
            shot(app, "04-no-cloud-gallery")
            throw XCTSkip("this build's gallery has no Cloud connect scene")
        }
        shot(app, "04-cloud-connect-gallery")
        // The wait reads as one element: what it waits on, then its bound.
        ergo("wait", wait.label, reason: wait.label.contains("through"), eta: wait.label.contains("up to"))
        XCTAssertTrue(wait.label.contains("through") && wait.label.contains("up to"), "reason and ETA: \(wait.label)")
        let failed = app.descendants(matching: .any)["cloudChats.connectFailed"].firstMatch
        XCTAssertTrue(failed.exists, "the timeout state\n\(app.debugDescription)")
        ergo("state", "Couldn't connect, with its cause and Retry", reason: true)
    }
}
