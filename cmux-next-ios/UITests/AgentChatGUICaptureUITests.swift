import XCTest

/// Before/after captures of the pushed agent chat (header, transcript, composer dock,
/// jump control, cards) on the shipping app's offline DEBUG chats, in light and dark.
/// Each screenshot is a keepAlways attachment named `agentgui~<state>~<look>`; the
/// fleet's simulator step exports them with their names (`ui-attachments/manifest.json`).
/// A state that cannot be reached fails its own assertion and the run goes on.
final class AgentChatGUICaptureUITests: XCTestCase {
    private enum Look: String, CaseIterable { case dark, light }
    private static let history = ["-cmux-mobile-demo", "disclosure-chat"]
    private static let empty = ["-cmux-mobile-demo", "kbd-chat-empty"]

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRestingStates() {
        for look in Look.allCases {
            scene("history-bottom", look, Self.history) { _ in }
            scene("history-scrolled-up", look, Self.history) { app in
                self.dragDown(app, times: 3)
                let jump = app.buttons["Jump to bottom"].firstMatch
                self.waitFor(jump, "jump control after scrolling up")
                // The circle rides the collapsed composer: its 44 pt host sits 8 pt above the
                // stack, so the gap to the capsule's "Reply to" row (6 pt inside the glass) is
                // about 14 pt. A dock left on the expanded composer's 96 pt put it ~55 pt up.
                let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
                if jump.exists, bar.waitForExistence(timeout: 5) {
                    let gap = bar.frame.minY - jump.frame.maxY
                    XCTAssertLessThan(gap, 24, "jump circle floats \(gap) pt above the composer (\(look))")
                    XCTAssertGreaterThan(gap, 4, "jump circle overlaps the composer (\(look))")
                }
            }
            scene("pending-question", look, ["-cmux-mobile-demo", "kbd-chat"]) { _ in }
            scene("empty-chat", look, Self.empty) { _ in }
            scene("offline-queued", look, ["-cmux-mobile-demo", "offline-send"], settle: 8) { _ in }
            scene("voice-mode", look, ["-cmux-mobile-demo", "voice-chat"],
                  env: ["CMUX_MOBILE_VOICE_MODE_DEMO": "1", "CMUX_MOBILE_VOICE_MODE_DEMO_PROMPT": "what changed today"]) { app in
                let voice = app.buttons["agentChat.composer.voice"].firstMatch
                self.waitFor(voice, "voice button")
                if voice.exists { voice.tap() }
                let bar = app.otherElements["voiceMode.bar"].firstMatch
                self.waitFor(bar, "voice bar", timeout: 10)
                // The bar sits above the navigation bar, never over its back button.
                // Back: the navigation bar's leading button.
                if bar.exists, let back = app.navigationBars.buttons.allElementsBoundByIndex.first(where: { $0.frame.minX < 60 }) {
                    XCTAssertLessThanOrEqual(bar.frame.maxY, back.frame.minY + 1, "voice bar covers the back button (\(look))")
                    XCTAssertTrue(back.isHittable, "back button is not hittable under the voice bar (\(look))")
                }
            }
        }
    }

    @MainActor
    func testComposerStates() {
        for look in Look.allCases {
            scene("keyboard-draft", look, Self.history) { app in
                self.openComposer(app)
                app.typeText("Run the tests")
            }
            scene("slash-suggestions", look, Self.history) { app in
                self.openComposer(app)
                app.typeText("/")
            }
            scene("select-text", look, Self.history, dock: false) { app in
                // The newest answer's first paragraph (a table, links and code follow it),
                // brought fully under the navigation bar with small drags (ChatSelectTextUITests).
                let paragraph = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "The transport switch holds up")).firstMatch
                let window = app.windows.firstMatch
                let barBottom = app.navigationBars.firstMatch.frame.maxY
                func clear() -> Bool { paragraph.exists && paragraph.frame.minY > barBottom + 8 && paragraph.frame.maxY < window.frame.maxY - 140 }
                for _ in 0..<6 where !clear() {
                    let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: paragraph.exists ? 120 : 180)))
                }
                XCTAssertTrue(clear(), "the answer paragraph is on screen (\(look))")
                guard clear() else { return }
                paragraph.press(forDuration: 1.2)
                let select = app.buttons["Select Text"].firstMatch
                self.waitFor(select, "Select Text in the answer's menu")
                guard select.exists else { return }
                select.tap()
                let field = app.textViews["selectText.text"]
                self.waitFor(field, "the selectable text")
                // The answer as read: no link targets, table rules, code ticks or bold marks.
                let text = (field.value as? String) ?? ""
                XCTAssertTrue(text.contains("The transport switch holds up"), "Select Text holds the answer (\(look))")
                for mark in ["](", "| ---", "|---", "`", "**"] {
                    XCTAssertFalse(text.contains(mark), "Select Text shows raw Markdown \"\(mark)\" (\(look))")
                }
            }
            scene("composer-dismissed", look, Self.history) { app in
                // Expanded (96 pt) with the keyboard, then the keyboard goes down with no draft:
                // the composer collapses to its capsule, and the transcript's dock must follow it.
                self.openComposer(app)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the keyboard went down (\(look))")
                self.pause(2)
            }
            scene("long-draft", look, Self.history) { app in
                self.openComposer(app)
                app.typeText("Check the transport layer, then the relay, then the dialer. Summarize what changed in each, list the tests that cover it, and say which of them you ran.")
            }
        }
    }

    @MainActor
    func testTurnStates() {
        for look in Look.allCases {
            scene("running-turn", look, Self.history, after: [("running-turn-later", 4)]) { app in
                // The offline demo chat's mock turn may finish before a Stop is drawn, so the
                // running state is captured, not asserted.
                self.send(app, "Summarize the transport layer")
            }
            scene("first-turn-permission", look, Self.empty, after: [("first-turn-later", 8)]) { app in
                self.send(app, "Plan the release")
            }
        }
    }

    // MARK: Helpers

    @MainActor
    private func scene(_ id: String, _ look: Look, _ args: [String], env: [String: String] = [:], settle: TimeInterval = 6,
                       after: [(String, TimeInterval)] = [], dock: Bool = true, _ drive: (XCUIApplication) -> Void) {
        XCUIDevice.shared.appearance = look == .dark ? .dark : .light
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.appearance", look.rawValue, "-cmux-mobile-kbd-trace"] + args
        // Each scene reads its own launch's frames.
        for trace in Self.traceFiles() { try? FileManager.default.removeItem(at: trace) }
        app.launch()
        defer { app.terminate() }
        let more = app.navigationBars.buttons["More"].firstMatch
        guard more.waitForExistence(timeout: 30) else {
            XCTFail("\(id) \(look): the agent chat did not open")
            return
        }
        pause(settle)
        drive(app)
        pause(1.2)
        attach(app, "agentgui~\(id)~\(look.rawValue)")
        if dock { checkDock("\(id) \(look)") }
        for (name, delay) in after {
            pause(delay)
            attach(app, "agentgui~\(name)~\(look.rawValue)")
            if dock { checkDock("\(name) \(look)") }
        }
    }

    /// The dock as the app drew its last frame (`-cmux-mobile-kbd-trace`): the transcript's
    /// stack height is the stack's laid-out height, and a transcript resting on its newest
    /// row ends 8 pt (`ChatTranscriptController.contentGap`) above the stack. A height left
    /// on an earlier composer (the expanded 96 pt one) held the rows ~40 pt above the
    /// collapsed capsule.
    @MainActor
    private func checkDock(_ what: String) {
        guard let frame = Self.lastTraceFrame() else {
            XCTFail("\(what): no trace frame (-cmux-mobile-kbd-trace) in the app's Documents")
            return
        }
        let line = frame.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let attachment = XCTAttachment(string: line)
        attachment.name = "agentgui~\(what.replacingOccurrences(of: " ", with: "~"))~dock"
        attachment.lifetime = .keepAlways
        add(attachment)
        func num(_ key: String) -> Double? { frame[key].flatMap(Double.init) }
        guard let stack = num("stackH"), let laidOut = num("reportedH") else {
            XCTFail("\(what): the trace has no stack heights (\(line))")
            return
        }
        XCTAssertEqual(stack, laidOut, accuracy: 0.5, "\(what): the transcript keeps a \(stack) pt stack, the stack is \(laidOut) pt")
        if let dockTop = num("dockTop"), let content = num("contentBottom"), let offset = num("offset"),
           let maxOffset = num("maxOffset"), abs(offset - maxOffset) < 1, frame["tracking"] == "0" {
            XCTAssertEqual(dockTop - content, 8, accuracy: 1.5, "\(what): the newest row ends \(dockTop - content) pt above the stack")
        }
    }

    /// `Documents/kbd-trace.txt` of the apps on this simulator (their data containers are
    /// siblings of this runner's).
    private static func traceFiles() -> [URL] {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let manager = FileManager.default
        let dirs = (try? manager.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("Documents/kbd-trace.txt") }.filter { manager.fileExists(atPath: $0.path) }
    }

    private static func lastTraceFrame() -> [String: String]? {
        for url in traceFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let last = text.split(separator: "\n").last(where: { $0.hasPrefix("t=") }) else { continue }
            var frame: [String: String] = [:]
            for pair in last.split(separator: " ") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { frame[String(kv[0])] = String(kv[1]) }
            }
            return frame
        }
        return nil
    }

    @MainActor
    private func openComposer(_ app: XCUIApplication) {
        let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        if bar.waitForExistence(timeout: 5) { bar.tap() }
        let field = app.textViews["chat.composer.field"].firstMatch
        if field.waitForExistence(timeout: 5), !app.keyboards.firstMatch.exists { field.tap() }
        waitFor(app.keyboards.firstMatch, "keyboard up")
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        openComposer(app)
        app.typeText(text)
        let send = app.buttons["Send"].firstMatch
        waitFor(send, "Send")
        if send.exists { send.tap() }
    }

    @MainActor
    private func dragDown(_ app: XCUIApplication, times: Int) {
        for _ in 0..<times {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                       withVelocity: .slow, thenHoldForDuration: 0)
        }
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) did not appear")
    }

    /// A bounded wait on the run loop for a scene to settle (capture timing only; no
    /// product code waits on it).
    @MainActor
    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
