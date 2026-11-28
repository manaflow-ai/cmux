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

    /// Leo, 2026-11-17: "Surely we can just calculate a f***ing terminal and
    /// resize whatever needs exceptions when it comes / Fall back if need be".
    ///
    /// The demo's `altproj` phase: htop already running in a Mac pane of
    /// 120x40 that answers a claim 60 ms later. The phone attaches into it,
    /// is rotated, pinched and double tapped, and shows and hides the
    /// keyboard: none of it may resize the Mac (the phone shows the Mac's
    /// grid, zoomed). Then `abc` is typed into htop: exactly one claim (the
    /// phone fits htop), `q` releases it, and htop started again fits at once,
    /// with no frame of it at a grid other than its final one.
    @MainActor
    func testAlternateScreenIsZoomedNotResizedAndTypingFitsOnce() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.settings.terminalPhoneProjection", "YES", "-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "altproj", "-cmuxMobile.settings.terminalZoomFullScreenApps", "YES"]
        if let chrome = ProcessInfo.processInfo.environment["CMUX_ZOOM_CHROME"] {
            app.launchArguments += ["-CmuxMobileTerminalZoomChrome", chrome]
        }
        app.launch()
        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")

        struct Alt: CustomStringConvertible {
            var mac = 0, claims = 0, replayBytes = 0, settleMs = -1, unsettled = 0, gestures = 0, zoom = 100, columns = -1
            var description: String {
                "mac PTY resizes \(mac), claims+releases \(claims), replay bytes \(replayBytes), settle \(settleMs) ms, "
                    + "frames at a grid not final \(unsettled), zoom gestures \(gestures), zoom \(zoom)%, columns \(columns)"
            }
            func since(_ b: Alt) -> Alt {
                Alt(mac: mac - b.mac, claims: claims - b.claims, replayBytes: replayBytes - b.replayBytes, settleMs: settleMs,
                    unsettled: unsettled - b.unsettled, gestures: gestures - b.gestures, zoom: zoom, columns: columns)
            }
        }
        func parse(_ label: String) -> (stage: String, Alt)? {
            let parts = label.split(separator: ".")
            guard parts.count >= 9, parts[0] == "a" else { return nil }
            var out = Alt()
            for part in parts.dropFirst(2) {
                func int(_ prefix: String) -> Int? { part.hasPrefix(prefix) ? Int(part.dropFirst(prefix.count)) : nil }
                if let n = int("mac") { out.mac = n }
                if let n = int("cl") { out.claims = n }
                if let n = int("rb") { out.replayBytes = n }
                if let n = int("st") { out.settleMs = n }
                if let n = int("uf") { out.unsettled = n }
                if let n = int("zg") { out.gestures = n }
                if let n = int("zs") { out.zoom = n }
                if let n = int("cols") { out.columns = n }
            }
            return (String(parts[1]), out)
        }
        func wait(for stage: String, timeout: TimeInterval = 90) -> Alt? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let (now, counts) = parse(probe.label), now == stage { return counts }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return nil
        }
        func now() -> Alt? {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            return parse(probe.label)?.1
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "altproj-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        var rows: [(String, Alt)] = []
        guard let attached = wait(for: "attach") else { return XCTFail("htop never settled: \(probe.label)") }
        rows.append(("attach into htop", attached))
        shot("attach-fit-width")
        var last = attached
        func step(_ name: String) {
            guard let counts = now() else { return }
            rows.append((name, counts.since(last)))
            last = counts
        }
        guard wait(for: "gestures", timeout: 20) != nil else { return XCTFail("no gestures stage: \(probe.label)") }
        XCUIDevice.shared.orientation = .landscapeLeft
        step("rotate to landscape")
        shot("landscape")
        XCUIDevice.shared.orientation = .portrait
        step("rotate back")
        let terminal = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        terminal.doubleTap()
        step("double tap (readable)")
        shot("readable")
        app.pinch(withScale: 1.8, velocity: 1.5)
        step("pinch out (zoomed)")
        shot("zoomed")
        // One finger pans the zoomed grid; it never reaches htop.
        terminal.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)))
        step("one-finger pan")
        shot("zoomed-panned")
        // On the app's own area: a pinch in on the whole window starts its
        // fingers outside the terminal (status bar, key bar), where the zoom
        // never sees them.
        let tuiArea = app.otherElements["terminal.tuiClip"].firstMatch
        let pinchTarget: XCUIElement = tuiArea.exists ? tuiArea : app
        print("projection ui: altproj: pinch in on \(tuiArea.exists ? "the terminal area" : "the window")")
        pinchTarget.pinch(withScale: 0.5, velocity: -1)
        pinchTarget.pinch(withScale: 0.5, velocity: -1)
        step("pinch in (fit width)")
        shot("fit-width-again")
        guard let gestured = wait(for: "gestured") else { return XCTFail("the demo never left the gestures stage: \(probe.label)") }
        rows.append(("(stage end)", gestured.since(last)))
        last = gestured
        guard let keyboard = wait(for: "kb") else { return XCTFail("the keyboard toggles never ended: \(probe.label)") }
        rows.append(("keyboard show and hide", keyboard.since(last)))
        last = keyboard
        guard let typed = wait(for: "typed") else { return XCTFail("typing never settled: \(probe.label)") }
        rows.append(("type abc into htop", typed.since(last)))
        last = typed
        shot("typed-fitted")
        guard let quit = wait(for: "quit") else { return XCTFail("q never landed: \(probe.label)") }
        rows.append(("q (htop exits)", quit.since(last)))
        last = quit
        guard let again = wait(for: "again") else { return XCTFail("htop never started again: \(probe.label)") }
        rows.append(("htop again (remembered)", again.since(last)))
        shot("again-remembered")

        for (name, counts) in rows {
            print("projection ui: altproj: \(name): \(counts)")
            XCTContext.runActivity(named: "altproj \(name): \(counts)") { _ in }
        }
        let attachment = XCTAttachment(string: rows.map { "projection ui: altproj: \($0.0): \($0.1)" }.joined(separator: "\n"))
        attachment.name = "projection-ui altproj " + rows.map {
            "\($0.0)=mac\($0.1.mac).cl\($0.1.claims).rb\($0.1.replayBytes).st\($0.1.settleMs).uf\($0.1.unsettled).zg\($0.1.gestures).zs\($0.1.zoom).cols\($0.1.columns)"
        }.joined(separator: " | ")
        attachment.lifetime = .keepAlways
        add(attachment)

        let named = Dictionary(rows.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(attached.mac, 0, "attaching into htop resized the Mac (\(attached))")
        XCTAssertEqual(attached.columns, 120, "htop is shown at the Mac's grid (\(attached))")
        for name in ["rotate to landscape", "rotate back", "double tap (readable)", "pinch out (zoomed)", "one-finger pan",
                     "pinch in (fit width)", "(stage end)", "keyboard show and hide"] {
            guard let counts = named[name] else { continue }
            XCTAssertEqual(counts.mac, 0, "\(name) resized the Mac (\(counts))")
        }
        XCTAssertGreaterThanOrEqual(gestured.gestures, 3, "pinch and double tap zoomed (\(gestured))")
        // Leo, 2026-11-25: "why would the Mac on an iPhone connection ALWAYS be resized down anyways!?"
        XCTAssertEqual(named["type abc into htop"]?.mac, 0, "typing into htop resized the Mac")
        XCTAssertEqual(named["type abc into htop"]?.columns, 120, "htop stays at the Mac's grid, scaled")
        XCTAssertEqual(named["q (htop exits)"]?.mac, 0, "htop exiting resized the Mac")
        XCTAssertEqual(named["htop again (remembered)"]?.mac, 0, "htop again resized the Mac")
        XCTAssertEqual(again.columns, 120, "htop again is at the Mac's grid, scaled")
    }

    /// A Mac that keeps its grid (Prefer this Mac): the phone claims nothing
    /// while it projects, so nothing waits for an answer. htop typed into,
    /// quit and started again: the Mac's PTY never resizes and htop shows at
    /// the Mac's grid (zoomed) at once, with no frame at a wrong grid. Each
    /// stage's first right frame (ms) is in the note.
    @MainActor
    func testAMacThatKeepsItsSizeFallsBackToItsGridZoomed() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.settings.terminalPhoneProjection", "YES", "-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "altproj", "-cmuxMobile.settings.terminalZoomFullScreenApps", "YES", "-CmuxMobileTerminalDemoMacKeepsSize", "YES"]
        app.launch()
        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")

        // `a.<stage>.mac<n>.cl<n>.rb<n>.st<ms>.uf<n>...cols<n>`, as the demo writes it.
        func wait(for stage: String, timeout: TimeInterval = 60) -> [String: Int]? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let parts = probe.label.split(separator: ".")
                if parts.count >= 9, parts[0] == "a", parts[1] == stage {
                    var out: [String: Int] = [:]
                    for part in parts.dropFirst(2) {
                        guard let digit = part.firstIndex(where: { $0 == "-" || $0.isNumber }), let n = Int(part[digit...]) else { continue }
                        out[String(part[..<digit])] = n
                    }
                    return out
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return nil
        }
        guard let attached = wait(for: "attach") else { return XCTFail("htop never settled: \(probe.label)") }
        guard let typed = wait(for: "typed") else { return XCTFail("typing never settled: \(probe.label)") }
        guard let again = wait(for: "again") else { return XCTFail("htop never started again: \(probe.label)") }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "altproj-keeps-size-again"
        shot.lifetime = .keepAlways
        add(shot)

        let rows = [("attach into htop", attached), ("type abc into htop", typed), ("htop again (remembered, no answer)", again)]
        let line = rows.map { row -> String in
            let (name, c) = row
            return "\(name)=mac\(c["mac"] ?? -1).cl\(c["cl"] ?? -1).rb\(c["rb"] ?? -1).st\(c["st"] ?? -1).uf\(c["uf"] ?? -1).cols\(c["cols"] ?? -1)"
        }.joined(separator: " | ")
        print("projection ui: altproj keeps size: \(line)")
        let attachment = XCTAttachment(string: line)
        attachment.name = "projection-ui altproj-keeps-size " + line
        attachment.lifetime = .keepAlways
        add(attachment)

        for (name, counts) in rows {
            XCTAssertEqual(counts["mac"], 0, "\(name): a Mac that keeps its size never resizes (\(counts))")
            XCTAssertEqual(counts["cols"], 120, "\(name): htop at the Mac's grid (\(counts))")
        }
        XCTAssertEqual(again["cl"], typed["cl"], "htop again claims nothing")
        let settle = again["st"] ?? -1
        XCTAssertGreaterThanOrEqual(settle, 0)
        XCTAssertLessThan(settle, 1_400, "no frame waits for a claim's answer")
        XCTAssertEqual(again["uf"], 0, "no frame of htop at a wrong grid (counted from the attach on), held or after")
    }

    /// The zoom chrome's gallery: htop on the Mac's 120x40 grid zoomed past
    /// fit width with each variant (none, a column ruler, a minimap strip),
    /// its chrome kept up for the screenshot. Leo (rulebook): "3+ gallery variants".
    @MainActor
    func testZoomChromeGallery() throws {
        for chrome in ["none", "ruler", "minimap"] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.settings.terminalPhoneProjection", "YES", "-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                    "-CmuxMobileTerminalDemoPhases", "altproj", "-cmuxMobile.settings.terminalZoomFullScreenApps", "YES", "-CmuxMobileTerminalZoomChrome", chrome,
                                    "-CmuxMobileTerminalZoomChromePinned", "YES"]
            app.launch()
            let probe = app.staticTexts["debug.terminal-demo"]
            XCTAssertTrue(probe.waitForExistence(timeout: 30))
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, !probe.label.hasPrefix("a.gestures.") {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            let terminal = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            terminal.doubleTap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            terminal.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25)))
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "altproj-gallery-\(chrome)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testClaudeCodeHeaderStaysVisibleAtHostGridScrollBottom() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.settings.terminalPhoneProjection", "YES", "-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo",
                                "-CmuxMobileHostGridDemo", "50x40,tui,header"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the host-grid demo did not open\n\(app.debugDescription)")
        let header = app.descendants(matching: .any)["terminal.tui.header"]
        let field = app.textViews["terminal.composer.field"]

        func assertHeader(_ state: String) {
            XCTAssertTrue(header.waitForExistence(timeout: 5), "Claude Code row 0 is not visible at \(state)\n\(probe.label)")
            XCTAssertTrue(header.isHittable, "Claude Code row 0 is clipped at \(state)\n\(probe.label)")
            XCTAssertGreaterThan(header.frame.height, 0, "Claude Code header has no height at \(state)")
        }

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertHeader("keyboard down, one-line composer")

        let keyboardKey = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(keyboardKey.waitForExistence(timeout: 5), "keyboard key\n\(app.debugDescription)")
        keyboardKey.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "keyboard up")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        assertHeader("keyboard up, one-line composer")

        XCTAssertTrue(field.waitForExistence(timeout: 5), "composer field\n\(app.debugDescription)")
        field.tap()
        field.typeText("one\ntwo\nthree\nfour\nfive")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        assertHeader("keyboard up, five-line composer")

        keyboardKey.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard down")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        assertHeader("keyboard down, five-line composer")
    }

    @MainActor
    private func run(macGrid: String?, name pane: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.settings.terminalPhoneProjection", "YES", "-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
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
        app.launchArguments += ["-cmuxMobile.settings.terminalPhoneProjection", "YES", "-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
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
