import XCTest

/// The terminal must not flicker when the keyboard shows or hides.
///
/// - A full-screen app (vim) never resizes for the keyboard either (Leo,
///   2026-11-15: "i meant previously there was the thing that stopped the
///   resizing when you closed the ios built in keyboard"): its grid keeps
///   its rows, the Mac never redraws for a toggle, and the grid on screen
///   never swaps: no blank grid, no letterbox note, no torn frame.
/// - A shell never resizes for the keyboard; its rows ride the keyboard,
///   never against it, never blank, and never snap after it stops.
///
/// The terminal demo (`-CmuxMobileTerminalDemoMac`: the mock answers a resize
/// the way the Mac does) toggles the keyboard five times (`kbtui`, `kbshell`);
/// the page's flicker trace (`-CmuxMobileTerminalFlickerTrace`) reads every
/// display frame from presentation layers and counts.
final class TerminalKeyboardToggleFlickerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFullScreenAppKeepsItsGridOnTheComposerAcrossToggles() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim"))
    }

    /// A Mac a 150 ms round trip away: the redraw at fewer rows arrives while
    /// the keyboard still rises and waits for it to stop.
    @MainActor
    func testFullScreenAppOnASlowLinkKeepsItsGridOnTheComposer() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim-slow", defaults: ["CmuxMobileTerminalDemoMacMs": "150"]))
    }

    /// A tap on the terminal shows the keyboard (the handler a tap runs).
    @MainActor
    func testFullScreenAppWithATapToShow() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim-tap", defaults: ["CmuxMobileTerminalDemoToggle": "tap"]))
    }

    /// Hidden from outside our code (the terminal resigns, as a swipe or the
    /// system does): only will-hide claims the rows.
    @MainActor
    func testFullScreenAppHiddenFromOutside() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim-system", defaults: ["CmuxMobileTerminalDemoToggle": "system"]))
    }

    /// Shown, then hidden 80 ms later on a 150 ms link: still no resize, and
    /// the page ends on its resting rows.
    @MainActor
    func testFullScreenAppToggleReversedBeforeTheMacAnswers() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim-reverse", defaults: ["CmuxMobileTerminalDemoToggle": "reverse",
                                                                                          "CmuxMobileTerminalDemoMacMs": "150"]))
    }

    /// Shown, hidden and shown again 100 ms apart.
    @MainActor
    func testFullScreenAppRapidDoubleToggle() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim-double", defaults: ["CmuxMobileTerminalDemoToggle": "double"]))
    }

    /// A light terminal theme (the Mac's Solarized Light).
    @MainActor
    func testFullScreenAppInALightTheme() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "vim-light", arguments: ["-CmuxMobileTerminalDemoLight"]))
    }

    /// htop reports the mouse; its screen redraws every 0.9 s on its own.
    @MainActor
    func testMouseReportingAppKeepsItsGridOnTheComposerAcrossToggles() throws {
        try checkFullScreenApp(try runDemo(phase: "kbtui", name: "htop", defaults: ["CmuxMobileTerminalDemoTUI": "htop"]))
    }

    @MainActor
    func testShellRidesTheKeyboardWithoutResizing() throws {
        checkShell(try runDemo(phase: "kbshell", name: "prompt"), following: true)
    }

    @MainActor
    func testLongOutputAtItsEndRidesTheKeyboard() throws {
        checkShell(try runDemo(phase: "kbshell", name: "follow", defaults: ["CmuxMobileTerminalDemoShell": "follow"]), following: true)
    }

    /// Scrolled up, the rows a reader looks at may stay where they are; they
    /// never move against the keyboard, blank or snap.
    @MainActor
    func testLongOutputScrolledUpNeverFlickers() throws {
        checkShell(try runDemo(phase: "kbshell", name: "reading", defaults: ["CmuxMobileTerminalDemoShell": "reading"]), following: false)
    }

    /// Rows streaming in move the page on their own: resizes, blank frames and
    /// the last row's distance to the composer are counted here.
    @MainActor
    func testStreamingOutputRidesTheKeyboard() throws {
        let values = try runDemo(phase: "kbshell", name: "stream", defaults: ["CmuxMobileTerminalDemoShell": "stream"])
        checkShell(values, motion: false)
        // The stream's own scrolling is not the toggle's motion: what is
        // checked is the last row against the composer, every frame. It rides
        // the composer through the keyboard's movement, off by at most the
        // one row a stream writes ahead of the follow scroll.
        XCTAssertEqual(values["gapoff"], "0", "frames the last row left the composer while following the stream: largest \(values["gapmax"] ?? "?") pt at \(values["offlog"] ?? "?")")
        XCTAssertEqual(values["drift"], "0", "frames the last row left the composer while following the stream")
    }

    /// An inline agent (Codex CLI's box) on the primary screen. Its document
    /// is shorter than the page, so with the keyboard down it rests at the
    /// top, not on the composer: its rows move with the keyboard only as far
    /// as they must.
    @MainActor
    func testInlineAgentRidesTheKeyboardWithoutResizing() throws {
        checkShell(try runDemo(phase: "kbshell", name: "inline", defaults: ["CmuxMobileTerminalDemoShell": "inline"]), following: false)
    }

    /// A full-screen app keeps its grid through every toggle: no resize, so
    /// the Mac never redraws for the keyboard and the grid on screen never
    /// swaps. With the keyboard up the grid's top is clipped and its body
    /// moves down by whole rows (`TerminalGridSizing.keyboardPlacement`), so
    /// the row-1 position checks of the old top-pinned layout do not apply.
    private func checkFullScreenApp(_ values: [String: String]) throws {
        let steps = resizeSteps(values)
        XCTAssertEqual(steps.count, 10, "five shows and five hides (\(values["demo"] ?? "-"))")
        for (step, resizes) in steps {
            XCTAssertEqual(resizes, 0, "the keyboard resized the full-screen app at \(step) (\(values["demo"] ?? "-"))")
        }
        let swaps = counts(values["swapn"])
        XCTAssertEqual(swaps.count, 10, "swap counts for five shows and five hides (\(values["swapn"] ?? "-"))")
        for (step, count) in swaps.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(count, 0, "the grid swapped at \(step) (\(values["swapn"] ?? "-"))")
        }
        XCTAssertEqual(values["inter"], "0", "intermediate grids drawn: \(values["offlog"] ?? "?")")
        XCTAssertEqual(values["blank"], "0", "frames with a blank grid")
        XCTAssertEqual(values["note"], "0", "frames with the letterbox note")
        XCTAssertEqual(values["sized"], "0", "frames where the surface changed size")
        // Hiding, the gap below the grid is background only.
        XCTAssertEqual(values["gaplive"], "0", "frames with live or stale rows below the grid: \(values["offlog"] ?? "?")")
        // Ghostty never presents a grid of other rows than the area's without
        // a committed still over it (a torn frame).
        XCTAssertEqual(values["torn"], "0", "frames with the new grid in the old area: \(values["offlog"] ?? "?")")
        // Measured, not asserted: row 1 against the toolbar's edge.
        XCTContext.runActivity(named: "topoff \(values["topoff"] ?? "?") rowoff \(values["rowoff"] ?? "?") off2 \(values["off2"] ?? "?")") { _ in }
    }


    private func checkShell(_ values: [String: String], following: Bool = false, motion: Bool = true) {
        let steps = resizeSteps(values)
        XCTAssertEqual(steps.count, 10, "five shows and five hides (\(values["demo"] ?? "-"))")
        XCTAssertTrue(steps.allSatisfy { $0.1 == 0 }, "the primary screen never resizes for the keyboard (\(values["demo"] ?? "-"))")
        XCTAssertEqual(values["blank"], "0", "frames with blank rows")
        guard motion else { return }
        XCTAssertEqual(values["rev"], "0", "frames where the rows moved against the keyboard")
        XCTAssertEqual(values["snap"], "0", "frames where the rows moved while the composer stood still")
        if following {
            XCTAssertEqual(values["gapoff"], "0", "frames the last row left the composer: largest \(values["gapmax"] ?? "?") pt at \(values["offlog"] ?? "?")")
            XCTAssertEqual(values["jump"], "0", "frames where the last row left the composer: largest \(values["jmax"] ?? "?") pt at \(values["jlog"] ?? "?")")
        }
    }

    /// The demo's toggles, then the trace's counts (`key=value`).
    @MainActor
    private func runDemo(phase: String, name: String, defaults: [String: String] = [:], arguments: [String] = []) throws -> [String: String] {
        let label = "\(phase)-\(name)"
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoMac", "-CmuxMobileTerminalFlickerTrace",
                                "-CmuxMobileTerminalDemoPhases", phase]
        for (key, value) in defaults { app.launchArguments += ["-\(key)", value] }
        app.launchArguments += arguments
        app.launch()

        let demo = app.staticTexts["debug.terminal-demo"]
        let probe = app.staticTexts["debug.terminal-flicker"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the flicker probe (-CmuxMobileTerminalFlickerTrace)")
        var shot: Set<String> = []
        var line = ""
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, !line.contains("demo=done.") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let step = demo.label
            for name in ["show0", "hide0"] where step.hasPrefix(name) && !shot.contains(name) {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                attach(app, "\(label)-\(name == "show0" ? "keyboard-up" : "keyboard-down")")
                shot.insert(name)
            }
            line = probe.value as? String ?? ""
        }
        // A frame or two more, so the summary has the last step.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        line = probe.value as? String ?? line
        let summary = XCTAttachment(string: line)
        summary.name = "\(label)-flicker-summary.txt"
        summary.lifetime = .keepAlways
        add(summary)
        let values = Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        if let path = values["file"]?.replacingOccurrences(of: "%20", with: " "),
           let trace = try? String(contentsOfFile: path, encoding: .utf8) {
            let attachment = XCTAttachment(string: trace)
            attachment.name = "\(label)-flicker-trace.txt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(line.contains("demo=done.rz"), "the demo finished (\(line))")
        return values
    }

    /// Each toggle step and its PTY resizes, from the demo's cumulative log
    /// (`demo=done....steps=show0:1,hide0:1,...`): a label the probe missed
    /// under load is still in it.
    /// `show0:1,hide0:1,...` as a map.
    private func counts(_ log: String?) -> [String: Int] {
        var out: [String: Int] = [:]
        for item in (log ?? "").split(separator: ",") {
            let kv = item.split(separator: ":")
            if kv.count == 2, let count = Int(kv[1]) { out[String(kv[0])] = count }
        }
        return out
    }

    private func resizeSteps(_ values: [String: String]) -> [(String, Int)] {
        let log = (values["demo"] ?? "").components(separatedBy: ".steps=").dropFirst().first ?? ""
        return log.split(separator: ",").compactMap { item -> (String, Int)? in
            let kv = item.split(separator: ":")
            guard kv.count == 2, let count = Int(kv[1]), kv[0].hasPrefix("show") || kv[0].hasPrefix("hide") else { return nil }
            return (String(kv[0]), count)
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
