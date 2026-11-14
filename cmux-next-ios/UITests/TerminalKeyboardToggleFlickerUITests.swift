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
        // Following the stream, the last row rides the composer through the
        // keyboard's movement: never a row or more off for two frames.
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
        XCTAssertEqual(steps.count, 10, "five shows and five hides (\(values["rz"] ?? "-"))")
        for (step, resizes) in steps {
            XCTAssertEqual(resizes, 1, "one resize for the settled toggle \(step) (\(values["rz"] ?? "-"))")
        }
        XCTAssertEqual(values["blank"], "0", "frames with a blank grid")
        XCTAssertEqual(values["note"], "0", "frames with the letterbox note")
        XCTAssertEqual(values["sized"], "0", "frames where the surface changed size")
        // Every frame, single ones and the held still included: the grid's
        // bottom row stays within 2 pt of where it rests on the composer.
        XCTAssertEqual(values["off2"], "0", "frames with the grid's bottom off the composer: largest \(values["off2max"] ?? "?") pt at \(values["offlog"] ?? "?")")
        XCTAssertEqual(values["snap"], "0", "frames where the grid moved while the composer stood still")
        // Measured, not asserted (the hide's band lasts the Mac's round trip).
        XCTContext.runActivity(named: "band: \(values["bandf"] ?? "?") frames, largest \(values["bandpx"] ?? "?") pt") { _ in }
        // The Mac's redraw lands about when the keyboard stops: no frame with
        // the old grid once the composer has stopped (a band above it, or its
        // top rows under the toolbar).
        XCTAssertEqual(values["late"], "0", "frames with the old grid after the keyboard stopped")
    }

    private func checkShell(_ values: [String: String], following: Bool = false, motion: Bool = true) {
        let steps = resizeSteps(values)
        XCTAssertEqual(steps.count, 10, "five shows and five hides (\(values["rz"] ?? "-"))")
        XCTAssertTrue(steps.allSatisfy { $0.1 == 0 }, "the primary screen never resizes for the keyboard (\(values["rz"] ?? "-"))")
        XCTAssertEqual(values["blank"], "0", "frames with blank rows")
        guard motion else { return }
        XCTAssertEqual(values["rev"], "0", "frames where the rows moved against the keyboard")
        XCTAssertEqual(values["snap"], "0", "frames where the rows moved while the composer stood still")
        if following {
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

    /// `rz=show0:1,hide0:1,...` as (step, resizes), toggles only.
    private func resizeSteps(_ values: [String: String]) -> [(String, Int)] {
        (values["rz"] ?? "").split(separator: ",").compactMap { item -> (String, Int)? in
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
