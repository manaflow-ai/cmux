import Darwin
import XCTest

/// Measures the app's display link between step marks, as the keyboard motion
/// bench does. Resolve touch locations before the mark and check the visible
/// result afterwards so an accessibility read cannot count as animation work.
final class AnimationFrameBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChatAnimations() throws {
        try XCTSkipIf(heavyDuress, "the heavy pass measures composer typing")
        let app = launch(["-cmux-mobile-demo", "kbd-chat"], labels: [
            "keyboard-show", "composer-grow", "jump-to-bottom", "keyboard-hide",
        ])
        defer { app.terminate() }
        let keyboard = app.keyboards.firstMatch
        let field = app.textViews["chat.composer.field"]
        let focus = composerFocusTarget(app)
        XCTAssertFalse(keyboard.exists)
        window("keyboard-show", in: app) { focus.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        app.typeText("one")
        let oneLine = field.frame.height
        // A software Return inserts a newline; the composer's hardware Return sends.
        let returnKey = keyboard.descendants(matching: .any).matching(NSPredicate(
            format: "label ==[c] 'return' OR identifier ==[c] 'return'"
        )).firstMatch
        let insertLine = center(returnKey, in: app)
        window("composer-grow", in: app) { insertLine.tap() }
        XCTAssertGreaterThan(field.frame.height, oneLine + 1, "inserting a newline grew the composer")

        // The short drag from ComposerGrowKeepsTranscriptUITests leaves the
        // keyboard up, with the transcript parked above the newest turn.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let jump = app.buttons["Jump to bottom"].firstMatch
        let jumpTarget = center(jump, in: app)
        XCTAssertTrue(keyboard.exists)
        window("jump-to-bottom", in: app) { jumpTarget.tap() }
        XCTAssertTrue(jump.waitForNonExistence(timeout: 10), "the transcript returned to the newest turn")
        XCTAssertTrue(keyboard.exists)

        let transcript = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        window("keyboard-hide", in: app) { transcript.tap() }
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
    }

    /// The fleet runs the same input once in isolation and once with duress=heavy.
    @MainActor
    func testComposerTyping() {
        let heavy = heavyDuress
        let label = heavy ? "composer-typing-heavy" : "composer-typing"
        let app = launch(["-cmux-mobile-demo", "kbd-chat"], labels: [label])
        defer { app.terminate() }
        composerFocusTarget(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let probe = app.staticTexts["debug.duress"]
        var before = 0
        if heavy {
            let running = NSPredicate(format: "label MATCHES %@", ".* records=[1-9][0-9]* .*")
            let started = XCTNSPredicateExpectation(predicate: running, object: probe)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 60), .completed, "duress replay delivered chat records")
            before = recordsDelivered(probe)
        }
        // Multiple keyboard-render frames and at least one update of the
        // duress player's once-a-second delivery counter.
        let text = "Measure typing in the composer while the recorded chat streams new messages into the transcript."
        window(label, in: app, verify: {
            guard field.value as? String == text else {
                XCTFail("all keystrokes must reach the chat composer")
                return false
            }
            if heavy {
                let after = self.recordsDelivered(probe)
                guard before > 0, after > before else {
                    XCTFail("duress chat records did not advance during typing (\(before) to \(after))")
                    return false
                }
                print("animation-frame composer-typing duress records=\(before)..\(after)")
            }
            return true
        }) { app.typeText(text) }
    }

    /// The existing simulator runner writes the absolute replay folder into
    /// the simulator's global defaults before launching XCTest and the app.
    private var heavyDuress: Bool {
        guard let path = UserDefaults.standard.string(forKey: "CmuxMobileDuress") else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == "heavy"
    }

    @MainActor
    private func recordsDelivered(_ probe: XCUIElement) -> Int {
        let token = probe.label.split(separator: " ").first { $0.hasPrefix("records=") }
        return token.flatMap { Int($0.dropFirst("records=".count)) } ?? 0
    }

    @MainActor
    func testWorkspaceAnimations() throws {
        try XCTSkipIf(heavyDuress, "the heavy pass measures composer typing")
        let app = launch(["-cmux-mobile-tab", "workspaces"], labels: [
            "workspace-enter", "tab-overview-zoom", "sheet-present", "sheet-dismiss", "workspace-exit",
        ])
        defer { app.terminate() }
        let row = app.buttons["workspace.row.ws-cmux"].firstMatch
        if !row.exists, app.scrollViews["setup.teams.choose"].waitForExistence(timeout: 5) {
            app.buttons["Manaflow"].tap()
        }
        let enter = center(row, in: app)
        window("workspace-enter", in: app) { enter.tap() }
        let tabs = app.buttons.matching(NSPredicate(
            format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'"
        )).firstMatch
        let overview = center(tabs, in: app)
        window("tab-overview-zoom", in: app) { overview.tap() }
        let card = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))

        // ScreenSharingSheetUITests drives this same offline sheet from the grid.
        let new = app.buttons["New"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let present = center(app.buttons["Screen Sharing"].firstMatch, in: app)
        window("sheet-present", in: app) { present.tap() }
        let done = app.buttons["screenSharing.done"].firstMatch
        let dismiss = center(done, in: app)
        window("sheet-dismiss", in: app) { dismiss.tap() }
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        // Return to the selected page before measuring the workspace pop.
        let closeGrid = app.buttons["Done"].firstMatch
        XCTAssertTrue(closeGrid.waitForExistence(timeout: 10))
        closeGrid.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let far = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
        window("workspace-exit", in: app) {
            edge.press(forDuration: 0.05, thenDragTo: far, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.isHittable, "the workspace list is interactive again")
    }

    @MainActor
    private func launch(_ arguments: [String], labels: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_ANIMATION_BENCH_LABELS"] = labels.joined(separator: ",")
        app.launchArguments = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-CmuxMobileFrameLog"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func composerFocusTarget(_ app: XCUIApplication) -> XCUICoordinate {
        // The demo's question card can collapse the field into a Reply button.
        let target = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR (elementType == %d AND label == %@)",
            "chat.composer.field", XCUIElement.ElementType.button.rawValue, "Reply to Claude"
        )).firstMatch
        return center(target, in: app)
    }

    @MainActor
    private func center(_ element: XCUIElement, in app: XCUIApplication) -> XCUICoordinate {
        XCTAssertTrue(element.waitForExistence(timeout: 30), element.description)
        XCTAssertTrue(element.isHittable, element.description)
        let frame = element.frame
        let bounds = app.frame
        return app.coordinate(withNormalizedOffset: CGVector(
            dx: (frame.midX - bounds.minX) / bounds.width,
            dy: (frame.midY - bounds.minY) / bounds.height
        ))
    }

    @MainActor
    private func window(_ label: String, in app: XCUIApplication, verify: () -> Bool = { true }, action: () -> Void) {
        mark("begin", label)
        action()
        // A coordinate tap can return before the last UIKit or scroll frame.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        mark("end", label)
        guard verify() else { return }
        let summary = app.staticTexts["debug.animationFrameSummary"]
        guard summary.waitForExistence(timeout: 10), let json = summary.value as? String else {
            XCTFail("no recorded summary for \(label)")
            return
        }
        let data = Data(json.utf8)
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["label"] as? String == label else {
            XCTFail("invalid or stale frame summary for \(label)")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "animation-frame-\(label).json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func mark(_ phase: String, _ label: String) {
        let name = "dev.cmux.mobile.animationframe.\(phase).\(label)"
        let ack = XCTestExpectation(description: "\(phase) \(label) acknowledged by the app")
        var token: Int32 = 0
        let registered = notify_register_dispatch(name + ".ack", &token, .global(qos: .userInitiated)) { @Sendable _ in ack.fulfill() }
        XCTAssertEqual(registered, 0, "register \(name).ack")
        defer { notify_cancel(token) }
        XCTAssertEqual(notify_post(name), 0, "post \(name)")
        XCTAssertEqual(XCTWaiter.wait(for: [ack], timeout: 10), .completed, name)
    }
}
