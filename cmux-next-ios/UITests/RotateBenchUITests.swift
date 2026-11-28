import QuartzCore
import XCTest

/// Optimum ledger row 8, ios-rotate (target: one 120 Hz frame, 8.3 ms). Leo, 2026-11-24:
/// "i never only want top x changes. you all need to be working through all useful ones end to
/// end to end." and "and we need to be measuring dynamic possibilities too".
///
/// A measurement, not a gate (scripts/measure/ios_rotate.py reads it; flows.json `rotate`). Per
/// surface, with the app's keyboard-pin trace on (`-cmux-mobile-kbd-pin-trace`: the window, the
/// scene's orientation, the composer field and the content behind it as drawn, every display
/// frame, plus `ev=deviceOrientation` when the app learns the phone turned) and its main-thread
/// tracer on (`-cmux-mobile-input-latency`: every run-loop iteration of 4 ms or more, with
/// stacks), it turns the phone to landscape and back 5 times, then 3 more times with the
/// keyboard up. The surfaces: the terminal page as the app shows it, the same page streaming a
/// 12,000-row Claude Code session every 16 ms (duress), the terminal against a scripted Mac that
/// answers the resize, and the agent chat (portrait on a phone: ScreenSharingOrientation).
///
/// Every turn is marked `rot-mark <CACurrentMediaTime> <surface> <method>.<direction>.<round>`
/// (one clock with the trace's `epoch=`), and the first turn also as `MOBILEBENCH flow=rotate`
/// lines for compare-mobile's video cut. Between turns the test only sleeps: no accessibility
/// query runs while the layout moves.
final class RotateBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private struct Surface {
        var name: String
        var arguments: [String]
        /// The element a tap focuses (the keyboard rounds).
        var field: @MainActor (XCUIApplication) -> XCUIElement
        /// Hides the keyboard.
        var hide: @MainActor (XCUIApplication) -> Void
        /// Ready to turn (load started, demo attached).
        var ready: @MainActor (XCUIApplication) -> Void = { _ in }
    }

    private static let base = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-kbd-pin-trace", "-cmux-mobile-input-latency"]

    @MainActor
    private static func terminalHide(_ app: XCUIApplication) {
        let key = app.buttons["terminal.key.keyboard"]
        if key.exists { key.tap() }
    }

    @MainActor
    func testTerminalRotate() throws {
        try bench(Surface(
            name: "terminal",
            arguments: ["-cmux-mobile-demo", "ws-terminal-idle"],
            field: { $0.textViews["terminal.composer.field"] },
            hide: Self.terminalHide))
    }

    /// Under duress: the mock Mac's Claude Code on the primary screen, 12,000 rows in the
    /// scrollback and its live region redrawn every 16 ms the whole time the phone turns.
    @MainActor
    func testTerminalRotateUnderStreamingLoad() throws {
        try bench(Surface(
            name: "terminal-load",
            arguments: ["-cmux-mobile-demo", "ws-terminal-idle"],
            field: { $0.textViews["terminal.composer.field"] },
            hide: Self.terminalHide,
            ready: { app in
                let field = app.textViews["terminal.composer.field"]
                guard field.waitForExistence(timeout: 30) else { return }
                field.tap()
                app.typeText("claudecli 12000 16")
                let send = app.buttons["terminal.composer.send"]
                if send.exists { send.tap() } else { app.typeText("\n") }
                Self.terminalHide(app)
                RunLoop.current.run(until: Date().addingTimeInterval(6))
            }))
    }

    /// The real terminal page and DaemonTerminalSession against a scripted Mac
    /// (TerminalLandscapeUITests): each turn asks the Mac for the new grid.
    @MainActor
    func testTerminalRotateWithMacResize() throws {
        try bench(Surface(
            name: "terminal-mac",
            arguments: ["-CmuxMobileResizeDemo"],
            field: { $0.textViews["terminal.composer.field"] },
            hide: Self.terminalHide,
            ready: { app in
                let step = app.staticTexts["debug.resize-demo"]
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline, step.label != "phone" {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
            }))
    }

    /// The agent chat stays portrait on a phone (ScreenSharingOrientation.resting): measured
    /// anyway, for what a turn costs a screen that does not turn.
    @MainActor
    func testAgentChatRotate() throws {
        try bench(Surface(
            name: "chat",
            arguments: ["-cmux-mobile-demo", "kbd-chat"],
            field: { app in
                let text = app.textViews["chat.composer.field"]
                return text.exists ? text : app.buttons["Reply to Claude"].firstMatch
            },
            hide: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }))
    }

    // MARK: - The run

    @MainActor
    private func bench(_ surface: Surface) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += Self.base + surface.arguments
        app.launch()

        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "\(surface.name): the keyboard pin probe (-cmux-mobile-kbd-pin-trace)")
        surface.ready(app)
        if app.keyboards.firstMatch.exists { surface.hide(app) }
        settle()
        attach(app, "\(surface.name)-portrait")
        mark(surface, "rest.rest.0")
        settle()

        for round in 0..<5 {
            if round == 0 { log(String(format: "MOBILEBENCH flow=rotate event=stimulus t=%.3f", Date().timeIntervalSince1970)) }
            turn(surface, to: .landscapeLeft, "rot.land.\(round)")
            if round == 0 {
                log(String(format: "MOBILEBENCH flow=rotate event=end t=%.3f", Date().timeIntervalSince1970))
                attach(app, "\(surface.name)-landscape")
            }
            turn(surface, to: .portrait, "rot.port.\(round)")
        }
        // With the keyboard up: the keyboard, the composer and the content all move with the turn.
        var notes: [String] = []
        for round in 0..<3 {
            let field = surface.field(app)
            if field.waitForExistence(timeout: 5), field.isHittable { field.tap() }
            settle()
            if !app.keyboards.firstMatch.exists { notes.append("kb.\(round): no keyboard after the tap") }
            turn(surface, to: .landscapeLeft, "kb.land.\(round)")
            if round == 0 { attach(app, "\(surface.name)-landscape-keyboard") }
            turn(surface, to: .portrait, "kb.port.\(round)")
            if app.keyboards.firstMatch.exists { surface.hide(app) }
            settle()
        }
        mark(surface, "end.end.0")
        settle(0.5)
        for note in notes { XCTContext.runActivity(named: note) { _ in } }
        log("rot-notes \(surface.name) \(notes.isEmpty ? "-" : notes.joined(separator: "; "))")
        dumpTrace(surface, probe)
    }

    @MainActor
    private func turn(_ surface: Surface, to orientation: UIDeviceOrientation, _ label: String) {
        mark(surface, label)
        XCUIDevice.shared.orientation = orientation
        settle(2.0)
    }

    /// Long enough for the system's turn, our layout after it, and a still stretch before the
    /// next step; nothing queries the app meanwhile.
    private func settle(_ seconds: TimeInterval = 1.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func mark(_ surface: Surface, _ label: String) {
        log(String(format: "rot-mark %.6f %@ %@", CACurrentMediaTime(), surface.name, label))
    }

    /// The marks and notes, printed and kept as rot-marks-SURFACE.txt (the simulator step's
    /// console export can come back empty).
    private var logged: [String] = []

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    @MainActor
    private func dumpTrace(_ surface: Surface, _ probe: XCUIElement) {
        let marks = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        marks.name = "rot-marks-\(surface.name).txt"
        marks.lifetime = .keepAlways
        add(marks)
        if let file = InputLatencyUITests.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) {
            let latency = XCTAttachment(string: text)
            latency.name = "rot-latency-\(surface.name).txt"
            latency.lifetime = .keepAlways
            add(latency)
        } else {
            print("rot-latency-missing \(surface.name)")
        }
        let line = probe.value as? String ?? ""
        let path = line.split(separator: " ").first { $0.hasPrefix("file=") }
            .map { String($0.dropFirst(5)).replacingOccurrences(of: "%20", with: " ") }
        guard let path, let trace = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("rot-trace-missing \(surface.name) \(path ?? "-")")
            XCTFail("\(surface.name): the trace file is unreadable (\(path ?? "no file= on the probe"))")
            return
        }
        let attachment = XCTAttachment(string: trace)
        attachment.name = "rot-trace-\(surface.name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
