import XCTest

/// A disclosure in the agent chat (a tool group, a tool call, a thought) opens and closes the way
/// ChatGPT's does (Aziz 2026-10-30): the line you tap stays where it is on screen while its body
/// grows down from under it, even with the chat resting on its newest row. Before, the transcript
/// re-pinned to the newest row as the body opened, so the tapped line jumped up by the body's height.
///
/// Each step prints a `CMUX_DISCLOSURE` line and attaches the frames it sampled while the body
/// opened and closed, the evidence for the before/after recordings.
final class AgentDisclosureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTappedDisclosureLineStaysPutWhileItOpensAndCloses() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat"]
        app.launch()
        defer { app.terminate() }

        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        // A prompt gets the demo's short turn: a thought, then "Read a file, ran a command" and
        // the answer under it, the chat following its newest row.
        // The agent chat shows its composer collapsed until tapped.
        let bar = app.buttons["Reply to Claude"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the composer bar is shown\n\(app.debugDescription)")
        bar.tap()
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer opens\n\(app.debugDescription)")
        for _ in 0..<5 where !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            field.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)], timeout: 2)
        }
        field.typeText("What is in the README?")
        app.buttons["Send"].firstMatch.tap()
        let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read a file")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 20), "the turn's tool group arrives\n\(app.debugDescription)")
        let stop = app.buttons["Stop"].firstMatch
        expect(stop, "exists == false", "the turn ends")
        let jump = app.buttons["Jump to bottom"].firstMatch
        expect(jump, "exists == false", "the chat rests on its newest row")

        // The lowest disclosure line on screen: opening it can only push rows below it, so the
        // view, resting on the newest row, must not move it.
        // Found again by its label (and its place among lines with that label): the rows the body
        // opens are buttons too, so an index into all disclosures would shift under it.
        let (label, nth) = lowestDisclosure(in: app)
        let header = app.buttons.matching(NSPredicate(format: "label == %@", label)).element(boundBy: nth)
        let before = header.frame
        print("CMUX_DISCLOSURE header '\(label)' at \(before)")
        attach(app, "0-before-open")

        header.tap()
        let opening = sample(app, header, "open")
        let opened = header.frame
        print("CMUX_DISCLOSURE opened: \(opened); sampled minY \(opening.map { Int($0) })")
        attach(app, "2-opened")
        for (index, y) in opening.enumerated() {
            XCTAssertEqual(y, before.minY, accuracy: 2, "frame \(index) of the open: '\(label)' moved from \(before.minY) to \(y)")
        }
        XCTAssertEqual(opened.minY, before.minY, accuracy: 2, "opened, '\(label)' moved from \(before.minY) to \(opened.minY)")

        header.tap()
        let closing = sample(app, header, "close")
        let closed = header.frame
        print("CMUX_DISCLOSURE closed: \(closed); sampled minY \(closing.map { Int($0) })")
        attach(app, "4-closed")
        for (index, y) in closing.enumerated() {
            XCTAssertEqual(y, before.minY, accuracy: 2, "frame \(index) of the close: '\(label)' moved from \(before.minY) to \(y)")
        }
        XCTAssertEqual(closed.minY, before.minY, accuracy: 2, "closed, '\(label)' moved from \(before.minY) to \(closed.minY)")
    }

    /// The disclosure line nearest the bottom of the transcript that is on screen and tappable.
    @MainActor
    private func lowestDisclosure(in app: XCUIApplication) -> (label: String, nth: Int) {
        let pattern = NSPredicate(format: "label MATCHES %@", "^(Read|Ran|Edited|Searched|Thought|Running|Reading).*")
        let candidates = app.buttons.matching(pattern)
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 15), "the demo chat has a disclosure\n\(app.debugDescription)")
        let screen = app.windows.firstMatch.frame
        let composer = app.textViews["chat.composer.field"]
        let composerTop = composer.exists ? composer.frame.minY - 24 : screen.maxY - 160
        var best: XCUIElement?
        var bestY = -CGFloat.infinity
        for index in 0..<candidates.count {
            let element = candidates.element(boundBy: index)
            let frame = element.frame
            guard element.isHittable, frame.minY > screen.minY + 120, frame.maxY < composerTop, frame.minY > bestY else { continue }
            best = element
            bestY = frame.minY
        }
        guard let best else {
            XCTFail("no disclosure on screen above the composer\n\(app.debugDescription)")
            return ("", 0)
        }
        let label = best.label
        let same = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let nth = (0..<same.count).first { abs(same.element(boundBy: $0).frame.minY - bestY) < 1 } ?? 0
        return (label, nth)
    }

    /// The header's top through the fold (about 0.35 s and its settle), with a few screens.
    @MainActor
    private func sample(_ app: XCUIApplication, _ header: XCUIElement, _ name: String) -> [CGFloat] {
        var tops: [CGFloat] = []
        let end = Date().addingTimeInterval(1.0)
        var frame = 0
        while Date() < end {
            tops.append(header.frame.minY)
            if frame < 4 {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "1-\(name)-frame-\(frame)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            frame += 1
        }
        return tops
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 20), .completed, message)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
