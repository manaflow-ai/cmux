import XCTest

/// The terminal must not flicker when the keyboard shows or hides.
///
/// - A full-screen app (vim) gets one PTY resize per settled toggle (R1-1);
///   the Mac answers with its grid, a mirror reset and a replay. Until the
///   new grid is drawn the old one stays pinned to the composer, then it
///   swaps in: no frame with the grid off the composer, no blank grid, no
///   letterbox note.
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

    private func checkFullScreenApp(_ values: [String: String]) throws {
        let steps = resizeSteps(values)
        XCTAssertEqual(steps.count, 10, "five shows and five hides (\(values["demo"] ?? "-"))")
        for (step, resizes) in steps {
            XCTAssertEqual(resizes, 1, "one resize for the settled toggle \(step) (\(values["demo"] ?? "-"))")
        }
        XCTAssertEqual(values["blank"], "0", "frames with a blank grid")
        XCTAssertEqual(values["note"], "0", "frames with the letterbox note")
        XCTAssertEqual(values["sized"], "0", "frames where the surface changed size")
        // Through every toggle the grid stays pinned to the top: row 1 at the
        // toolbar's edge on every frame (held stills included), never riding
        // the composer.
        XCTAssertEqual(values["topoff"], "0", "frames with row 1 off the toolbar's edge: largest \(values["topmax"] ?? "?") pt at \(values["offlog"] ?? "?")")
        XCTAssertEqual(values["topmove"], "0", "frames where the grid's top moved without a swap: \(values["offlog"] ?? "?")")
        // Hiding, the gap below the old grid is background only.
        XCTAssertEqual(values["gaplive"], "0", "frames with live or stale rows below the grid: \(values["offlog"] ?? "?")")
        // After the swap the bottom row rests on the composer.
        XCTAssertEqual(values["off2"], "0", "frames with the swapped grid off the composer: largest \(values["off2max"] ?? "?") pt at \(values["offlog"] ?? "?")")
        // Ghostty never presents a grid of other rows than the area's without
        // a committed still over it (a torn frame).
        XCTAssertEqual(values["torn"], "0", "frames with the new grid in the old area: \(values["offlog"] ?? "?")")
        // Measured, not asserted: the gap below the grid while hiding, the
        // old grid after the composer stopped, toggle start to the swap.
        XCTContext.runActivity(named: "gap below the grid: \(values["gapf"] ?? "?") frames, largest \(values["gappx"] ?? "?") pt; late \(values["late"] ?? "?"); swap \(values["swapms"] ?? "?") ms") { _ in }
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
    private func runDemo(phase: String, name: String, defaults: [String: String] = [:]) throws -> [String: String] {
        let label = "\(phase)-\(name)"
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoMac", "-CmuxMobileTerminalFlickerTrace",
                                "-CmuxMobileTerminalDemoPhases", phase]
        for (key, value) in defaults { app.launchArguments += ["-\(key)", value] }
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
