import XCTest

/// Gallery of the quiet mark on a sent bubble the Mac has not shown yet (Leo 2026-11-24, relayed:
/// "i think we can maybe be more optimistic sometimes"; "i also couldnt cancel out of the send"):
/// the shipped `glyph` and two variants (`edge`, `caption`), each on a send still being retried
/// (`offline-send-waiting`, after its 2 s) and on one given up (`offline-send`), then the
/// long-press menu (Cancel, Edit, Retry Now, Delete) and Cancel, which empties the bubble into
/// the composer. Screens only; it asserts no taste beyond the bubble staying put.
final class PendingMarkGalleryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testPendingMarkVariants() {
        for variant in ["glyph", "edge", "caption"] {
            for (demo, look) in [("offline-send-waiting", "retrying"), ("offline-send", "failed")] {
                let app = XCUIApplication()
                app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo,
                                        "-cmux-mobile-pending-mark-variant", variant]
                app.launch()
                defer { app.terminate() }
                let text = "Run the release checklist"
                guard send(app, text) else { XCTFail("\(variant)-\(look): could not send"); continue }
                let bubble = app.staticTexts[text].firstMatch
                XCTAssertTrue(bubble.waitForExistence(timeout: 10), "\(variant)-\(look): the bubble is drawn")
                let drawnAt = bubble.frame
                // The waiting mark comes after 2 s; the failed one at once.
                _ = app.descendants(matching: .any)[look == "failed" ? "Not sent" : "Waiting to send"].firstMatch
                    .waitForExistence(timeout: 6)
                if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .fast) }
                Thread.sleep(forTimeInterval: 0.6) // test: the keyboard's slide ends before the shot
                shot(app, "\(variant)-\(look)")
                XCTAssertEqual(bubble.frame.size, drawnAt.size, "\(variant)-\(look): the mark shifts no layout")
                guard variant == "glyph" else { continue }
                bubble.press(forDuration: 1.0)
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.waitForExistence(timeout: 5) {
                    shot(app, "\(variant)-\(look)-menu")
                    cancel.tap()
                    let field = app.textViews["chat.composer.field"]
                    _ = field.waitForExistence(timeout: 5)
                    XCTAssertEqual(field.value as? String, text, "\(look): Cancel gives the text back")
                    shot(app, "\(variant)-\(look)-cancelled")
                } else {
                    XCTFail("\(look): no Cancel in the bubble's menu\n\(app.debugDescription)")
                }
            }
        }
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) -> Bool {
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) {
            let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
            if bar.waitForExistence(timeout: 10) { bar.tap() }
        }
        guard field.waitForExistence(timeout: 10) else { return false }
        if !app.keyboards.firstMatch.exists { field.tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 8)
        field.typeText(text)
        let send = app.buttons["Send"].firstMatch
        guard send.waitForExistence(timeout: 5) else { return false }
        send.tap()
        return true
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "pending-mark-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
