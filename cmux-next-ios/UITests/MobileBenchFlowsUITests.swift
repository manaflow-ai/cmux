import XCTest

/// The cmux side of the mobile animation and latency benchmark (scripts/mobile-bench/flows.json):
/// Leo, 2026-11-19: "looking at the mobile apps and their various, you know, animations, their
/// flows ... for like [another chat app] or Claude ... the actual like measurement to measurement speeds,
/// the benchmarks". The same flows are recorded for the other apps; this suite drives ours on a
/// simulator with mock sign-in and the DEBUG demo data, while `cmux-next-ios-sim.sh test
/// ui=MobileBenchFlowsUITests video` records the screen.
///
/// Each test rests about a second, prints `MOBILEBENCH flow=ID event=stimulus t=EPOCH` right
/// before its one input, `event=input_done` when XCUITest returns from it (a tap waits for the
/// app to idle first, so the touch lands between the two), and `event=end` once the screen has
/// settled. `t` is wall-clock seconds, the host's clock (the simulator shares it); the script's
/// `MOBILEBENCH video-start` line puts them on the recording, and scripts/mobile-bench/cut.py cuts
/// one clip per flow. A flow the app has no counterpart for prints `unsupported reason=...`.
///
/// Measured timings are read from the video, not from these tests; the assertions only check
/// that each flow reached the state its clip should end on.
final class MobileBenchFlowsUITests: XCTestCase {
    override func setUp() {
        // A flow that misses a step still prints its end, so the run's other clips are cut.
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Flows, in flows.json order (XCTest runs them by name).

    @MainActor
    func test01_coldLaunchToTyping() {
        let flow = "cold-launch-to-typing"
        // One launch first, so the measured one is from killed rather than the first after install.
        let warm = launch(tab: "home")
        _ = waitForShell(warm, timeout: 30)
        warm.terminate()
        idle(1.5)

        let app = configured(tab: "home")
        mark(flow, "stimulus")
        app.launch()
        mark(flow, "input_done")
        defer { app.terminate() }
        // The app opens on Home (its chat list); typing starts from Home's compose button, which
        // opens New Message with its To: field focused.
        XCTAssertTrue(waitForShell(app, timeout: 30), "\(flow): the shell\n\(app.debugDescription)")
        let compose = app.buttons["home.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "\(flow): Home's compose button")
        compose.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 4) {
            app.textFields["conversation.compose.to"].tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6), "\(flow): the keyboard and caret")
        idle(1.2)
        mark(flow, "end")
    }

    @MainActor
    func test02_newChat() {
        let flow = "new-chat"
        let app = launch(demo: "new-message")
        defer { app.terminate() }
        let compose = app.buttons["home.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 30), "\(flow): Home's compose button\n\(app.debugDescription)")
        _ = app.buttons["home.row.conv-builder"].waitForExistence(timeout: 10)
        idle(1.2)
        mark(flow, "stimulus")
        compose.tap()
        mark(flow, "input_done")
        XCTAssertTrue(app.textFields["conversation.compose.to"].waitForExistence(timeout: 10), "\(flow): New Message opens")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test03_sendToFirstToken() {
        let flow = "send-to-first-token"
        // disclosure-chat: an idle chat with history whose next prompt gets the mock's short turn
        // (a thought 0.5 s after the send, two tools, a short answer).
        let app = launch(demo: "disclosure-chat")
        defer { app.terminate() }
        guard let field = openComposer(app, flow) else { return mark(flow, "end") }
        field.typeText("What is in the README?")
        idle(1.2)
        let send = app.buttons["Send"].firstMatch
        mark(flow, "stimulus")
        send.tap()
        mark(flow, "input_done")
        let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read a file")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 20), "\(flow): the turn's first output\n\(app.debugDescription)")
        idle(1.0)
        mark(flow, "end")
    }

    @MainActor
    func test04_streamLongAnswer() {
        let flow = "stream-long-answer"
        // CMUX_MOBILE_LIST_STREAM=1: the prompt's answer is one long stream (about 375 characters
        // a second, ListStressSettings.swift), with no tools or waits.
        let app = launch(demo: "disclosure-chat", env: ["CMUX_MOBILE_LIST_STREAM": "1"])
        defer { app.terminate() }
        guard let field = openComposer(app, flow) else { return mark(flow, "end") }
        field.typeText("Write me a long summary of the transport work.")
        idle(1.2)
        let send = app.buttons["Send"].firstMatch
        mark(flow, "stimulus")
        send.tap()
        mark(flow, "input_done")
        let stop = app.buttons["Stop"].firstMatch
        guard stop.waitForExistence(timeout: 10) else {
            XCTFail("\(flow): the streaming turn did not show Stop\n\(app.debugDescription)")
            mark(flow, "end")
            return
        }
        XCTAssertTrue(waitGone(stop, timeout: 150), "\(flow): the stream ends")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test05_scrollFling() {
        let flow = "scroll-fling"
        let app = launch(demo: "disclosure-chat")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30), "\(flow): the chat\n\(app.debugDescription)")
        // Start away from the newest row so the catalogue's upward swipe can move the transcript.
        fling(app)
        let jump = app.buttons["Jump to bottom"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "\(flow): history is scrolled away from the bottom")
        idle(1.5)
        mark(flow, "stimulus")
        fling(app, fromY: 0.8, toY: 0.25)
        mark(flow, "input_done")
        idle(3.0)
        mark(flow, "end")
    }

    @MainActor
    func test06_scrollToBottom() {
        let flow = "scroll-to-bottom"
        let app = launch(demo: "disclosure-chat")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30), "\(flow): the chat\n\(app.debugDescription)")
        idle(1.0)
        fling(app)
        idle(1.5)
        fling(app)
        let jump = app.buttons["Jump to bottom"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "\(flow): Jump to bottom shows away from the newest row")
        idle(2.0)
        mark(flow, "stimulus")
        jump.tap()
        mark(flow, "input_done")
        XCTAssertTrue(waitGone(jump, timeout: 5), "\(flow): at the newest row")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test07_keyboardShow() {
        let flow = "keyboard-show"
        let app = launch(demo: "kbd-chat")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30), "\(flow): the chat\n\(app.debugDescription)")
        if app.keyboards.firstMatch.waitForExistence(timeout: 2) { tapTranscript(app); _ = waitGone(app.keyboards.firstMatch, timeout: 5) }
        idle(1.2)
        let target = composerTarget(app)
        mark(flow, "stimulus")
        target.tap()
        mark(flow, "input_done")
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { app.textViews["chat.composer.field"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "\(flow): the keyboard")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test08_keyboardHide() {
        let flow = "keyboard-hide"
        let app = launch(demo: "kbd-chat")
        defer { app.terminate() }
        guard openComposer(app, flow) != nil else { return mark(flow, "end") }
        idle(1.2)
        // A tap on the transcript lowers the keyboard (TranscriptTapDismissUITests).
        mark(flow, "stimulus")
        tapTranscript(app)
        mark(flow, "input_done")
        XCTAssertTrue(waitGone(app.keyboards.firstMatch, timeout: 5), "\(flow): the keyboard goes")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test09_composerGrow() {
        let flow = "composer-grow"
        let app = launch(demo: "kbd-chat")
        defer { app.terminate() }
        guard let field = openComposer(app, flow) else { return mark(flow, "end") }
        idle(1.2)
        mark(flow, "stimulus")
        field.typeText("this is a longer message for the agent that runs past the first line\nsecond line\nthird line\nfourth line\nfifth line")
        mark(flow, "input_done")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test10_attachImage() {
        let flow = "attach-image"
        let app = launch(demo: "kbd-chat")
        defer { app.terminate() }
        guard openComposer(app, flow) != nil else { return mark(flow, "end") }
        idle(1.2)
        let add = lowest(app.buttons.matching(NSPredicate(format: "label == %@", "Add")))
        mark(flow, "stimulus")
        add.tap()
        mark(flow, "input_done")
        let photos = app.buttons["Photos"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "\(flow): the + menu's Photos\n\(app.debugDescription)")
        photos.tap()
        // The system photo picker: the simulator's library has a few stock photos.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo")).firstMatch
        if photo.waitForExistence(timeout: 8) {
            photo.tap()
            let done = app.navigationBars.buttons["Add"].firstMatch
            if done.waitForExistence(timeout: 2) { done.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["attachment.thumb"].firstMatch.waitForExistence(timeout: 8),
                          "\(flow): the thumbnail in the composer\n\(app.debugDescription)")
        } else {
            XCTFail("\(flow): no photo in the picker\n\(app.debugDescription)")
        }
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test11_switchChat() {
        let flow = "switch-chat"
        // Another chat of the open workspace, picked from its tab grid (AgentCardOpenShiftUITests).
        let app = launch(tab: "workspaces")
        defer { app.terminate() }
        let row = app.buttons["workspace.row.ws-cmux"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(flow): the ws-cmux row\n\(app.debugDescription)")
        row.tap()
        idle(2.0)
        let tabs = app.buttons["Tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "\(flow): the Tabs button")
        tabs.tap()
        let card = app.buttons.matching(NSPredicate(format: "label == 'Refactor transport layer, tab'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "\(flow): the agent tab's card\n\(app.debugDescription)")
        idle(2.5)
        mark(flow, "stimulus")
        card.tap()
        mark(flow, "input_done")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
            .waitForExistence(timeout: 10), "\(flow): the selected chat's composer\n\(app.debugDescription)")
        idle(2.0)
        mark(flow, "end")
    }

    @MainActor
    func test12_sidebarOpen() {
        let flow = "sidebar-open"
        // Home's Teams button opens the team drawer from the left.
        let app = launch(tab: "home")
        defer { app.terminate() }
        let teams = app.buttons["Teams"].firstMatch
        XCTAssertTrue(teams.waitForExistence(timeout: 30), "\(flow): the Teams button\n\(app.debugDescription)")
        idle(1.5)
        mark(flow, "stimulus")
        teams.tap()
        mark(flow, "input_done")
        XCTAssertTrue(app.buttons["Close teams"].firstMatch.waitForExistence(timeout: 5), "\(flow): the drawer opens")
        idle(1.5)
        mark(flow, "end")
    }

    @MainActor
    func test13_voiceStart() {
        let flow = "voice-start"
        // Voice mode with the DEBUG scripted Realtime link (VoiceModeUITests): no key, no microphone.
        let app = launch(demo: "voice-chat", env: ["CMUX_MOBILE_VOICE_MODE_DEMO": "1",
                                                   "CMUX_MOBILE_VOICE_MODE_DEMO_PROMPT": "What changed today?"])
        defer { app.terminate() }
        let voice = app.buttons["agentChat.composer.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 30), "\(flow): the voice button\n\(app.debugDescription)")
        idle(1.5)
        mark(flow, "stimulus")
        voice.tap()
        mark(flow, "input_done")
        XCTAssertTrue(app.staticTexts["voiceMode.caption"].firstMatch.waitForExistence(timeout: 10), "\(flow): the voice bar")
        idle(2.0)
        mark(flow, "end")
        let end = app.buttons["voiceMode.end"].firstMatch
        if end.exists { end.tap() }
    }

    @MainActor
    func test14_settingsOpen() {
        let flow = "settings-open"
        let app = launch(tab: "home")
        defer { app.terminate() }
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "\(flow): the Settings tab\n\(app.debugDescription)")
        idle(1.5)
        mark(flow, "stimulus")
        settings.tap()
        mark(flow, "input_done")
        XCTAssertTrue(settings.isSelected, "\(flow): Settings is selected after the tap\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "\(flow): the Settings page\n\(app.debugDescription)")
        idle(2.0)
        mark(flow, "end")
    }

    @MainActor
    func test15_rotate() {
        let flow = "rotate"
        let app = launch(tab: "home")
        defer {
            // Keep XCTest's next UI test in the same known orientation even when an
            // assertion above fails. RotateBenchUITests owns the repeated/duress runs.
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        guard waitForShell(app, timeout: 30) else {
            XCTFail("\(flow): the shell\n\(app.debugDescription)")
            mark(flow, "end")
            return
        }
        idle(1.5)
        mark(flow, "stimulus")
        XCUIDevice.shared.orientation = .landscapeLeft
        mark(flow, "input_done")
        // The compare-mobile clip ends after the first settled landscape frame. The
        // dedicated rotation bench continues with keyboard and load rounds separately.
        idle(2.0)
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft,
                       "\(flow): the simulator did not land in landscape\n\(app.debugDescription)")
        mark(flow, "end")
    }

    @MainActor
    func test16_offlineError() {
        let flow = "offline-error"
        // offline-send: a chat whose Mac is not reachable. Its demo sends one prompt as the chat
        // opens (queued); the measured send is a second one, typed and sent by hand, which
        // shows as queued for when the Mac is back.
        let app = launch(demo: "offline-send")
        defer { app.terminate() }
        let queued = app.descendants(matching: .any)["chat.queued"].firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 30), "\(flow): the demo's first queued prompt\n\(app.debugDescription)")
        guard let field = openComposer(app, flow) else { return mark(flow, "end") }
        field.typeText("Are you there?")
        idle(1.2)
        let send = app.buttons["Send"].firstMatch
        guard send.waitForExistence(timeout: 10), send.isHittable else {
            XCTFail("\(flow): the Send button\n\(app.debugDescription)")
            mark(flow, "end")
            return
        }
        let queuedCount = app.descendants(matching: .any).matching(identifier: "chat.queued").count
        mark(flow, "stimulus")
        send.tap()
        mark(flow, "input_done")
        XCTAssertTrue(waitForCount(app.descendants(matching: .any).matching(identifier: "chat.queued"),
                                   atLeast: queuedCount + 1, timeout: 10),
                      "\(flow): the sent prompt is queued offline\n\(app.debugDescription)")
        idle(1.5)
        mark(flow, "end")
    }

    // MARK: Helpers

    private func mark(_ flow: String, _ event: String) {
        print("MOBILEBENCH flow=\(flow) event=\(event) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
    }

    @MainActor
    private func configured(demo: String? = nil, tab: String? = nil, env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        if let demo { app.launchArguments += ["-cmux-mobile-demo", demo] }
        if let tab { app.launchArguments += ["-cmux-mobile-tab", tab, "-cmux-mobile-no-restore"] }
        return app
    }

    @MainActor
    private func launch(demo: String? = nil, tab: String? = nil, env: [String: String] = [:]) -> XCUIApplication {
        let app = configured(demo: demo, tab: tab, env: env)
        app.launch()
        return app
    }

    /// The tab bar, past the team chooser a mock account with several teams may show first.
    @MainActor
    private func waitForShell(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let choose = app.scrollViews["setup.teams.choose"]
        while Date() < deadline {
            if app.tabBars.firstMatch.exists { return true }
            if choose.exists { app.buttons["Manaflow"].firstMatch.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.tabBars.firstMatch.exists
    }

    /// The agent chat's field, open and focused with the keyboard up.
    @MainActor
    private func openComposer(_ app: XCUIApplication, _ flow: String) -> XCUIElement? {
        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30), "\(flow): the chat\n\(app.debugDescription)")
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 3) { composerTarget(app).tap() }
        guard field.waitForExistence(timeout: 10) else {
            XCTFail("\(flow): the composer field\n\(app.debugDescription)")
            return nil
        }
        for _ in 0..<5 where !app.keyboards.firstMatch.exists {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "\(flow): the keyboard")
        return field
    }

    /// The collapsed composer capsule ("Reply to …"), or the open field.
    @MainActor
    private func composerTarget(_ app: XCUIApplication) -> XCUIElement {
        let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        return capsule.exists ? capsule : app.textViews["chat.composer.field"]
    }

    @MainActor
    private func tapTranscript(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }

    /// One fast drag released with no hold (AgentJumpDuringMomentumUITests).
    @MainActor
    private func fling(_ app: XCUIApplication, fromY: CGFloat = 0.25, toY: CGFloat = 0.8) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
            .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY)),
                   withVelocity: XCUIGestureVelocity(5000), thenHoldForDuration: 0)
    }

    @MainActor
    private func lowest(_ query: XCUIElementQuery) -> XCUIElement {
        let all = query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        return all.max { $0.frame.minY < $1.frame.minY } ?? query.firstMatch
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Waits for a repeated accessibility element to appear without treating an old
    /// queued row as proof that this send was accepted.
    @MainActor
    private func waitForCount(_ query: XCUIElementQuery, atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return query.count >= count
    }

    /// Lets the screen rest (no input) for `seconds`.
    private func idle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
