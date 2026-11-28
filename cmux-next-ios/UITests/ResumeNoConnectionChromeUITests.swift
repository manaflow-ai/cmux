import XCTest

/// Leo, 2026-11-22: "i dont wanna see connecting to cosmic-gray... with the spinner, i want it to
/// just work. i dont wanna see reconnecting to the Mac in a toast, i want it to just connect."
///
/// The read-back of his flow: an open agent chat, the app sent to the background (its link
/// drops), brought back, and the link back only 12 s later, past the old 10 s notice bound
/// (`-cmux-mobile-demo resume-chat`). Frame by frame through the outage, the chat shows its kept
/// rows and no connection text. A message sent during it shows at once, with no "Not sent" (the
/// deadline is 60 s), and the Mac's reply arrives once the link is back. It also prints
/// `RESUME_NUMBERS` (foreground to first rows, to a composer that takes a send) for the PR.
final class ResumeNoConnectionChromeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // Computed: a stored static NSPredicate is not Sendable, an error under Swift 6.
    private static var chrome: NSPredicate {
        NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "Connecting", "Reconnecting", "Updating…", "reconnecting to the Mac")
    }

    @MainActor
    func testResumeShowsNoConnectionChrome() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "resume-chat"]
        app.launch()
        defer { app.terminate() }

        let bar = app.buttons["Reply to Claude"]
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "the chat opens with its rows\n\(app.debugDescription)")
        attach(app, "before-background")

        XCUIDevice.shared.press(.home)
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "background")], timeout: 3)
        let foregroundAt = Date()
        app.activate()

        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the kept chat is back at once")
        let firstRows = Date().timeIntervalSince(foregroundAt)
        bar.tap()
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer opens while the link is still down")
        for _ in 0..<5 where !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            field.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)], timeout: 2)
        }
        let sendable = Date().timeIntervalSince(foregroundAt)
        field.typeText("What is in the README?")
        app.buttons["Send"].firstMatch.tap()
        let bubble = app.staticTexts["What is in the README?"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 2), "the message shows the moment it is sent")
        let bubbleShown = Date().timeIntervalSince(foregroundAt)
        print("RESUME_NUMBERS foreground_to_rows_s=\(String(format: "%.2f", firstRows)) foreground_to_sendable_s=\(String(format: "%.2f", sendable)) foreground_to_sent_bubble_s=\(String(format: "%.2f", bubbleShown)) link_back_after_s=12")

        // Through the outage and past the old 10 s bound: no connection text, no toast, no Not sent.
        for frame in 0..<18 {
            let hits = app.descendants(matching: .any).matching(Self.chrome)
            XCTAssertEqual(hits.count, 0, "no connection text at frame \(frame): \(hits.allElementsBoundByIndex.map(\.label))")
            XCTAssertFalse(app.descendants(matching: .any)["agentChat.connectionLine"].exists, "no connection line at frame \(frame)")
            XCTAssertFalse(app.descendants(matching: .any)["agentChat.notSent"].exists, "no Not sent inside the deadline")
            attach(app, String(format: "outage-%02d", frame))
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 0.8)
        }
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Read a file", "Worked for")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the held message reaches the Mac once the link is back\n\(app.debugDescription)")
        XCTAssertEqual(app.descendants(matching: .any).matching(Self.chrome).count, 0)
        attach(app, "after-link-back")
    }

    @MainActor
    func testNotSentGalleryVariants() {
        for look in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-cmux-mobile-recovery-gallery", "notsent", "-cmux-mobile-gallery-appearance", look]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["recoveryGallery.notsent.variants"].waitForExistence(timeout: 30))
            attach(app, "notsent-gallery-\(look)")
            app.terminate()
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
