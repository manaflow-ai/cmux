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
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "altproj"]
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
            static func - (a: Alt, b: Alt) -> Alt {
                Alt(mac: a.mac - b.mac, claims: a.claims - b.claims, replayBytes: a.replayBytes - b.replayBytes, settleMs: a.settleMs,
                    unsettled: a.unsettled - b.unsettled, gestures: a.gestures - b.gestures, zoom: a.zoom, columns: a.columns)
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
            rows.append((name, counts - last))
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
        app.pinch(withScale: 0.2, velocity: -1.5)
        step("pinch in (fit width)")
        shot("fit-width-again")
        guard let gestured = wait(for: "gestured") else { return XCTFail("the demo never left the gestures stage: \(probe.label)") }
        rows.append(("(stage end)", gestured - last))
        last = gestured
        guard let keyboard = wait(for: "kb") else { return XCTFail("the keyboard toggles never ended: \(probe.label)") }
        rows.append(("keyboard show and hide", keyboard - last))
        last = keyboard
        guard let typed = wait(for: "typed") else { return XCTFail("typing never settled: \(probe.label)") }
        rows.append(("type abc into htop", typed - last))
        last = typed
        shot("typed-fitted")
        guard let quit = wait(for: "quit") else { return XCTFail("q never landed: \(probe.label)") }
        rows.append(("q (htop exits)", quit - last))
        last = quit
        guard let again = wait(for: "again") else { return XCTFail("htop never started again: \(probe.label)") }
        rows.append(("htop again (remembered)", again - last))
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
        XCTAssertEqual(named["type abc into htop"]?.mac, 1, "typing into htop fits it with exactly one resize")
        XCTAssertLessThan(named["type abc into htop"]?.columns ?? 120, 120, "fitted: htop at the phone's columns")
        XCTAssertEqual(named["q (htop exits)"]?.mac, 1, "htop exiting releases the phone's grid")
        XCTAssertEqual(named["htop again (remembered)"]?.mac, 1, "htop again fits at once (remembered)")
        XCTAssertEqual(named["htop again (remembered)"]?.unsettled, 0, "no frame of htop at the Mac's grid before it fits")
        XCTAssertLessThan(again.columns, 120, "htop again is at the phone's columns")
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
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                    "-CmuxMobileTerminalDemoPhases", "altproj", "-CmuxMobileTerminalZoomChrome", chrome,
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
