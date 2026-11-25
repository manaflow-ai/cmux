import XCTest

/// Leo, 2026-11-12: "does the iPhone now, like, just do the projection? Like
/// it calculates it itself and it's all, like, identical, or I mean, like,
/// better than before maybe?" and "when i load in it show me uncompact then
/// squish well iphone should do more work it lazy relaxing!?"
///
/// Leo, 2026-11-15: "ugh im getting a headache seeing the terminal bounce up
/// and down when the ios built in keyboard shows and hides", "i dont see the
/// point of a narrower-than-iphone terminal" and "you just need to prove the
/// behaviour is full with the projection style or whatever and then it's gtg".
///
/// The terminal demo's `projection` phase: a shell on a Mac pane
/// (`MacPaneMockSession`, "Fit the smallest viewer") of 120x40, or of 39x26
/// (narrower than the phone, the pane Leo saw), through the session the app
/// builds for a Mac terminal, on the real terminal page. The demo shows and
/// hides the keyboard; this test then switches to the home screen and back,
/// and rotates the phone to landscape and back. The demo's label keeps
/// `p.<stage>.mac<Mac PTY resizes>.wide<wide grids>.rs<mirror resets>
/// .ret<ms>.nar<narrow frames>.kbb<keyboard bounces>`.
/// Each action's counts are printed (`projection ui:` lines) for the PR's
/// table. None may resize the Mac or show the Mac's grid instead of the
/// phone's; through the keyboard, no frame may show a terminal narrower than
/// the phone, and the cursor's row never moves against the keyboard.
final class TerminalProjectionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private struct Counts: Equatable, CustomStringConvertible {
        var mac = 0
        var wide = 0
        var resets = 0
        /// The last return's time to the first right frame (ms; -1 none yet).
        var returnMs = -1
        /// Keyboard frames narrower than the phone.
        var narrow = 0
        /// Keyboard frames whose cursor row moved against the keyboard.
        var bounces = 0
        var description: String {
            "mac PTY resizes \(mac), wide grids \(wide), resets \(resets), first right frame \(returnMs) ms, "
                + "narrower-than-phone frames \(narrow), keyboard bounces \(bounces)"
        }
        static func - (a: Counts, b: Counts) -> Counts {
            Counts(mac: a.mac - b.mac, wide: a.wide - b.wide, resets: a.resets - b.resets, returnMs: a.returnMs,
                   narrow: a.narrow - b.narrow, bounces: a.bounces - b.bounces)
        }
    }

    private func counts(_ label: String) -> Counts? {
        // p.<stage>.mac<n>.wide<n>.rs<n>.ret<n>.nar<n>.kbb<n>
        var out = Counts()
        var found = 0
        for part in label.split(separator: ".") {
            if part.hasPrefix("mac"), let n = Int(part.dropFirst(3)) { out.mac = n; found += 1 }
            if part.hasPrefix("wide"), let n = Int(part.dropFirst(4)) { out.wide = n; found += 1 }
            if part.hasPrefix("rs"), let n = Int(part.dropFirst(2)) { out.resets = n; found += 1 }
            if part.hasPrefix("ret"), let n = Int(part.dropFirst(3)) { out.returnMs = n }
            if part.hasPrefix("nar"), let n = Int(part.dropFirst(3)) { out.narrow = n; found += 1 }
            if part.hasPrefix("kbb"), let n = Int(part.dropFirst(3)) { out.bounces = n; found += 1 }
        }
        return found == 5 ? out : nil
    }

    @MainActor
    func testPrimaryScreenNeverResizesTheMac() throws {
        run(macGrid: nil, name: "120x40")
    }

    /// A Mac pane narrower than the phone (Leo's 39x26): the phone still
    /// shows its own full width, with and without the keyboard.
    @MainActor
    func testANarrowMacPaneIsFullWidthOnThePhone() throws {
        run(macGrid: "39x26", name: "39x26")
    }

    @MainActor
    private func run(macGrid: String?, name pane: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "projection"]
        if let macGrid { app.launchArguments += ["-CmuxMobileTerminalDemoMacGrid", macGrid] }
        app.launch()
        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")

        func wait(for stage: String, timeout: TimeInterval = 60) -> Counts? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let label = probe.label
                if label.hasPrefix("p.\(stage)."), let counts = counts(label) { return counts }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return nil
        }
        func now() -> Counts? {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            return counts(probe.label)
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(pane)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        var rows: [(String, Counts)] = []
        guard let attached = wait(for: "kbstart") else { return XCTFail("the demo never attached: \(probe.label)") }
        rows.append(("attach", attached))
        shot("attached")
        guard wait(for: "kbup") != nil else { return XCTFail("the keyboard never came up: \(probe.label)") }
        // The probe only counts while a soft keyboard moves: it must be on screen.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the soft keyboard is on screen")
        shot("keyboard-up")
        guard let keyboard = wait(for: "kb") else { return XCTFail("the keyboard toggles never ended: \(probe.label)") }
        rows.append(("keyboard show and hide", keyboard - attached))
        guard var last = wait(for: "live") else { return XCTFail("no live counts: \(probe.label)") }

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.activate()
        _ = probe.waitForExistence(timeout: 10)
        if let back = now() {
            rows.append(("app switch (3 s)", back - last))
            last = back
        }
        shot("back-from-home")

        // Lock, then unlock (the simulator's lock button, when XCUIDevice has it).
        let lock = NSSelectorFromString("pressLockButton")
        if XCUIDevice.shared.responds(to: lock) {
            XCUIDevice.shared.perform(lock)
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCUIDevice.shared.press(.home)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.activate()
            _ = probe.waitForExistence(timeout: 10)
            if let back = now() {
                rows.append(("lock and unlock (3 s)", back - last))
                last = back
            }
            shot("back-from-lock")
        } else {
            print("projection ui: \(pane): lock and unlock: no lock button in this XCUIDevice")
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        if let turned = now() {
            rows.append(("rotate to landscape", turned - last))
            last = turned
        }
        shot("landscape")
        XCUIDevice.shared.orientation = .portrait
        if let back = now() {
            rows.append(("rotate back", back - last))
            last = back
        }
        shot("portrait-again")

        for (name, counts) in rows {
            print("projection ui: \(pane): \(name): \(counts)")
            XCTContext.runActivity(named: "\(pane) \(name): \(counts)") { _ in }
        }
        // The counts as an attachment too: its name reaches the step's
        // attachment manifest (the PR's table reads it from there).
        let table = rows.map { "projection ui: \(pane): \($0.0): \($0.1)" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: table)
        attachment.name = "projection-ui \(pane) " + rows.map {
            "\($0.0)=mac\($0.1.mac).wide\($0.1.wide).rs\($0.1.resets).ret\($0.1.returnMs).nar\($0.1.narrow).kbb\($0.1.bounces)"
        }.joined(separator: " | ")
        attachment.lifetime = .keepAlways
        add(attachment)
        for (name, counts) in rows {
            XCTAssertEqual(counts.mac, 0, "\(pane) \(name) resized the Mac's PTY (\(counts))")
            XCTAssertEqual(counts.wide, 0, "\(pane) \(name) drew the Mac's grid instead of the phone's (\(counts))")
            XCTAssertEqual(counts.narrow, 0, "\(pane) \(name) showed a terminal narrower than the phone (\(counts))")
            XCTAssertEqual(counts.bounces, 0, "\(pane) \(name) moved the terminal against the keyboard (\(counts))")
        }
    }
}

/// Leo, 2026-11-23: "if the data was sent through... why cant you simply
/// scroll through the depiction that was already given?" The demo's
/// `tuiheld` phases: a full-screen app without the mouse whose transcript
/// scrolls off its region's top, behind the phone's projection. One finger
/// reads back through it for 10 s (drags toward older rows, twice as many as
/// back toward newer, so the reader never passes the live screen): every pan
/// is painted on the phone from the rows it already drew, so the phone sends
/// the Mac 0 bytes in 0 sends and the app scrolls 0 times. `NoHeldRows`
/// variants run the same pans with every wheel sent to the app (the path
/// before held rows): the "before" in one harness. `-load` streams a row
/// every 16 ms throughout: the reader stays where they read (dictator,
/// 2026-11-24: output while panned into held rows does not return to live).
/// Each readout is a
/// `tuiheld ...` attachment (frames, receive-to-paint, gesture-to-paint).
extension TerminalProjectionUITests {
    @MainActor func testPanWithinHeldRowsSendsNothing() throws {
        try heldPan(variant: "keys", holds: true)
    }

    @MainActor func testPanWithinHeldRowsWhileStreamingSendsNothing() throws {
        try heldPan(variant: "keys-load", holds: true)
    }

    @MainActor func testPanWithoutHeldRowsScrollsTheApp() throws {
        try heldPan(variant: "keys", holds: false)
    }

    @MainActor func testPanWithoutHeldRowsWhileStreamingScrollsTheApp() throws {
        try heldPan(variant: "keys-load", holds: false)
    }

    private static func value(_ name: String, in demo: String) -> Int? {
        demo.split(separator: " ").lazy.compactMap { word -> Int? in
            let pair = word.split(separator: "=", maxSplits: 1)
            return pair.count == 2 && pair[0] == name ? Int(pair[1]) : nil
        }.first
    }

    @MainActor
    private func heldPan(variant: String, holds: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "tuiheld-\(variant)"]
        if !holds { app.launchArguments.append("-CmuxMobileTerminalDemoNoHeldRows") }
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        var deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuiheld-\(variant) ready") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        XCTAssertTrue(demo.hasPrefix("tuiheld-\(variant) ready"), "the app is up with rows held: \(demo)")

        let window = app.windows.firstMatch
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let panEnd = Date().addingTimeInterval(10)
        var drags = 0
        while Date() < panEnd {
            // Older, older, newer: a thumb reading back with a glance down.
            let older = drags % 3 != 2
            (older ? high : low).press(forDuration: 0.02, thenDragTo: older ? low : high,
                                      withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0)
            drags += 1
        }

        deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuiheld-\(variant) done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        let sendsPerDrag = drags > 0 ? Double(Self.value("sends", in: demo) ?? 0) / Double(drags) : 0
        let label = "tuiheld \(holds ? "held" : "noheld") \(demo) drags=\(drags)"
            + String(format: " sendsPerDrag=%.2f", sendsPerDrag)
        print(label)
        let numbers = XCTAttachment(string: label + "\n")
        numbers.name = "tuiheld-\(holds ? "held" : "noheld")-\(variant) " + demo
        numbers.lifetime = .keepAlways
        add(numbers)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tuiheld-\(holds ? "held" : "noheld")-\(variant)-end"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(demo.hasPrefix("tuiheld-\(variant) done"), "the phase finished: \(demo)")

        var values: [String: Int] = [:]
        for word in demo.split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { values[String(pair[0])] = value }
        }
        XCTAssertTrue(demo.contains("isTUI=true"), "the app is on the alternate screen: \(demo)")
        XCTAssertGreaterThan(values["frames"] ?? 0, 60, "frames were measured while the finger panned: \(demo)")
        if holds {
            XCTAssertGreaterThan(values["heldPaints"] ?? 0, 0, "the pans were painted from held rows: \(demo)")
            XCTAssertEqual(values["sends"] ?? -1, 0, "a pan within held rows sent the Mac nothing: \(demo)")
            XCTAssertEqual(values["bytes"] ?? -1, 0, "a pan within held rows sent 0 bytes: \(demo)")
            XCTAssertEqual(values["appScrolls"] ?? -1, 0, "the app never scrolled: \(demo)")
            // Read back, then the finger lifts: the app's output (a row every
            // 16 ms under `-load`) leaves the reader where they are.
            XCTAssertGreaterThan(values["back"] ?? 0, 0, "the reader is still back after the app's output: \(demo)")
        } else {
            XCTAssertGreaterThan(values["appScrolls"] ?? 0, 0, "every pan went to the app: \(demo)")
        }
    }
}
