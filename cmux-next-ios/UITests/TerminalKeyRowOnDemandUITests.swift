import XCTest

/// Leo, 2026-11-23: "the buttons atop the composer in the terminal warrant a redesign. why are those things always showing? ... and the buttons are really small."
final class TerminalKeyRowOnDemandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyRowAppearsAt44PointsOnlyWhileKeyboardIsUp() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle", "-cmux-mobile-kbd-pin-trace"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["terminal.composer.field"]
        let keyboard = app.keyboards.firstMatch
        let key = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        attach("1-keyboard-down-no-keys")
        XCTAssertFalse(keyboard.exists)
        XCTAssertFalse(key.exists && key.isHittable, "the key row is hidden on launch")

        field.tap()
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let probe = app.staticTexts["debug.kbd-pin"]
        Thread.sleep(forTimeInterval: 1.5)
        let hittable = key.isHittable
        let line = probe.value as? String ?? "-"
        let others = ["terminal.key.composer", "terminal.key.control", "terminal.key.escape"].map { id -> String in
            let element = app.buttons[id]
            return "\(id)=\(element.exists ? (element.isHittable ? "hit" : "nohit") : "none")@\(element.exists ? element.frame : .zero)"
        }.joined(separator: " ")
        let summary = "hittable=\(hittable) keyframe=\(key.frame) field=\(field.isHittable ? "hit" : "nohit")@\(field.frame) kb=\(keyboard.frame) \(others) probe=\(line)"
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "diag-tree"; tree.lifetime = .keepAlways; add(tree)
        let att = XCTAttachment(string: summary)
        att.name = "diag-probe"; att.lifetime = .keepAlways; add(att)
        XCTAssertTrue(key.waitForHittable(timeout: 3), "the key row opens with the keyboard DIAG \(summary)")
        // The row's slot opens with the keyboard (0.25 s): read the key once it has.
        let open = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in key.frame.height >= 44 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 3), .completed, "the key is \(key.frame)")
        attach("2-keyboard-up-keys-44pt")
        XCTAssertGreaterThanOrEqual(key.frame.height, 44)
        XCTAssertGreaterThanOrEqual(key.frame.width, 44)
        XCTAssertEqual(key.label, "Hide Keyboard")

        key.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        XCTAssertTrue(key.waitForNonExistence(timeout: 5) || !key.isHittable)
        attach("3-keyboard-down-again")
    }

    @MainActor
    func testKeyBarGalleryCapture() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "keybar", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        for style in ["caps", "strip", "inset"] {
            let row = app.descendants(matching: .any)["keyBarGallery.style.\(style)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "missing \(style) gallery row")
        }
        attach("keybar-gallery")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
