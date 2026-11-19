import XCTest

/// The agent chat arrives collapsed (Leo, 2026-11-17: "can we also just for the gui on ios collapse
/// the agent messages that come in by default? rn they're all showing ... rn they're just all
/// expanded and it's kinda undreadable :("), as the Mac transcript folds it: a finished turn's work
/// under one "Worked for" line with its reply under it, and another agent's message as its sender's
/// line and first line, each opening in place. The offline DEBUG chat (`disclosure-chat`) has both.
///
/// It scrolls the whole chat before it asserts, so a recording (`cmux-next-ios-sim.sh test ui=… video`)
/// shows the chat as it reads, before and after the change.
final class AgentChatCollapseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAgentMessagesArriveCollapsed() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat"]
        app.launch()
        defer { app.terminate() }

        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        sleep(1)
        attach(app, "0-chat-newest")

        // The whole chat, newest to oldest, as a reader scrolls it.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        for step in 0..<10 {
            top.press(forDuration: 0.05, thenDragTo: bottom)
            if step % 3 == 2 { attach(app, "1-scrolled-up-\(step)") }
        }

        // Another agent's message: its sender's line and its first line; the rest opens on a tap.
        let incoming = app.buttons["agent-chat.incoming-line"].firstMatch
        for _ in 0..<12 where !incoming.isHittable {
            bottom.press(forDuration: 0.05, thenDragTo: top)
        }
        XCTAssertTrue(incoming.isHittable, "another agent's message draws as one line that opens\n\(app.debugDescription)")
        let rest = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "the audit names sender and target")).firstMatch
        XCTAssertFalse(rest.exists, "a message that came in is not drawn in full until opened")
        attach(app, "2-incoming-closed")
        incoming.tap()
        XCTAssertTrue(rest.waitForExistence(timeout: 5), "the line opens the whole message in place")
        attach(app, "3-incoming-open")
        incoming.tap()

        // A finished turn: "Worked for", its reply under it; the work opens on a tap.
        // Looked up on every element: the line can reach the tree as its text and chevron. The
        // demo's folded turn is above the messages, so scroll back up to it.
        let worked = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Worked for"))
        for _ in 0..<12 where !worked.firstMatch.exists {
            top.press(forDuration: 0.05, thenDragTo: bottom)
        }
        XCTAssertTrue(worked.firstMatch.waitForExistence(timeout: 10), "a finished turn's work folds under Worked for\n\(app.debugDescription)")
        let line = worked.allElementsBoundByIndex.last { $0.isHittable } ?? worked.firstMatch
        for _ in 0..<12 where !line.isHittable {
            bottom.press(forDuration: 0.05, thenDragTo: top)
        }
        XCTAssertTrue(line.label.hasPrefix("Worked for") || line.label.hasPrefix("Failed after") || line.label.hasPrefix("You stopped after"),
                      "the line says how long the turn worked: \(line.label)")
        let work = NSPredicate(format: "label MATCHES %@", "^(Read|Ran|Edited|Searched|Thought).*")
        let shut = app.descendants(matching: .any).matching(work).count
        // VoiceOver: the closed line is one button that says it is collapsed (the tree VoiceOver reads).
        let button = app.buttons["agent-chat.worked-for"].firstMatch
        XCTAssertTrue(button.exists, "the closed line reaches VoiceOver as a button\n\(app.debugDescription)")
        XCTAssertTrue(button.label.hasPrefix("Worked for") || button.label.hasPrefix("Failed after") || button.label.hasPrefix("You stopped after"),
                      "the button reads how long the turn worked: \(button.label)")
        XCTAssertEqual(button.value as? String, "Collapsed", "VoiceOver hears that the line is collapsed")
        attachTree(button, "4-worked-closed-accessibility")
        attach(app, "4-worked-closed")
        line.tap()
        sleep(1)
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(work).count, shut, "opened, the turn's work shows under the line")
        let opened = app.buttons["agent-chat.worked-for"].firstMatch
        XCTAssertEqual(opened.value as? String, "Expanded", "VoiceOver hears that the line opened")
        attachTree(opened, "5-worked-open-accessibility")
        attach(app, "5-worked-open")
        line.tap()
        sleep(1)
        attach(app, "6-worked-closed-again")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The element as the accessibility tree has it (type, identifier, label, value), kept with the run.
    @MainActor
    private func attachTree(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(string: element.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\(name): \(element.debugDescription)")
    }
}
