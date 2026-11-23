import QuartzCore
import XCTest

/// Leo, 2026-11-23: "there's like various little like odd little like shifts
/// when I like arrive at the terminal. Like it doesn't settle well. ... it
/// needs to be fast even under load, under extreme load as well."
///
/// A measurement, not a gate. From the Workspaces list, a tap on a
/// workspace whose open tab is a terminal (`ws-ios`, its `xcodebuild` tab)
/// arrives at the terminal; an edge swipe goes back; 24 times, after one cold
/// arrival. The app's keyboard pin trace with its arrival fields
/// (`-cmux-mobile-kbd-pin-trace -cmux-mobile-arrival-trace`, TerminalArrivalFields)
/// writes the terminal page's views as drawn every display frame: the page,
/// the surface, the bottom stack, the key row, the composer and its field,
/// the navigation bar and its items, the tab bar, and Ghostty's presents
/// (the first paint).
///
/// Each arrival is marked `kbm-mark <CACurrentMediaTime> arrival arrive.<n>`
/// (the cold one `cold.arrive.0`), each way back `leave.<n>`; nothing queries
/// the app between a tap and its way back, so the frames are the app's own.
/// The analyzer is scripts/measure/ios_terminal_arrival.py.
///
/// Load: under the simulator step's `duress=` (any but off: the simulator's
/// global `CmuxMobileDuress` default is set), the terminal arrived at also
/// runs `claudecli 12000 16` (12,000 transcript rows, its live region redrawn
/// every 16 ms) the whole time, so every arrival lands on a long session
/// streaming. The marks' `arr-cond` line names the condition.
final class TerminalArrivalBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    static let rounds = 24
    static let workspace = "ws-ios"

    @MainActor
    func testArrivalFromWorkspacesList() throws {
        XCUIDevice.shared.orientation = .portrait
        let duress = UserDefaults.standard.string(forKey: "CmuxMobileDuress")
        let loaded = duress != nil
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux-mobile-kbd-pin-trace", "-cmux-mobile-arrival-trace"]
        app.launch()
        log("arr-cond \(loaded ? "load" : "idle") duress=\(duress.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "off")")
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the keyboard pin probe (-cmux-mobile-kbd-pin-trace)")
        let path = (probe.value as? String ?? "").split(separator: " ").first { $0.hasPrefix("file=") }
            .map { String($0.dropFirst(5)).replacingOccurrences(of: "%20", with: " ") }
        let row = app.buttons["workspace.row.\(Self.workspace)"]
        guard row.waitForExistence(timeout: 30) else {
            XCTFail("no row \(Self.workspace)\n\(app.debugDescription)")
            attachTrace(path)
            return
        }
        settle(1.5)

        // The cold arrival: the terminal page made for the first time.
        mark("cold.arrive.0")
        row.tap()
        settle(3.0)
        attach(app, "arrival-cold")
        let field = app.textViews["terminal.composer.field"]
        if !field.waitForExistence(timeout: 15) { log("kbm-notes arrival cold: no terminal composer on \(Self.workspace)") }
        if loaded, field.exists {
            // The load: a long session streaming in the terminal arrived at.
            mark("setup.load.0")
            field.tap()
            field.typeText("claudecli 12000 16")
            let send = app.buttons["terminal.composer.send"]
            if send.waitForExistence(timeout: 5) { send.tap() } else { field.typeText("\n") }
            settle(4.0)
            let key = app.buttons["terminal.key.keyboard"]
            if app.keyboards.firstMatch.exists, key.exists { key.tap() }
            settle(1.5)
            attach(app, "arrival-load")
        }
        mark("cold.leave.0")
        leave(app)

        for round in 0..<Self.rounds {
            if !row.waitForExistence(timeout: 30) {
                log("kbm-notes arrival \(round): no row after the way back")
                leave(app)
                continue
            }
            settle(1.0)
            mark("arrive.\(round)")
            row.tap()
            // The tap, the push, the first paint and whatever moves after it: no query meanwhile.
            settle(3.0)
            if round == 0 { attach(app, "arrival-warm") }
            mark("leave.\(round)")
            leave(app)
        }
        mark("end.end.0")
        settle(0.5)
        attachTrace(path)
    }

    /// Back to the list: the edge swipe, else the page's Back.
    @MainActor
    private func leave(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        settle(1.0)
        if app.buttons["workspace.row.\(Self.workspace)"].waitForExistence(timeout: 3) { return }
        let back = app.buttons["Back"].firstMatch
        if back.exists, back.isEnabled { back.tap() } else { log("kbm-notes arrival: no way back (swipe and Back)") }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var logged: [String] = []

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    private func mark(_ label: String) {
        log(String(format: "kbm-mark %.6f arrival %@", CACurrentMediaTime(), label))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func attachTrace(_ path: String?) {
        let marks = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        marks.name = "kbm-marks-arrival.txt"
        marks.lifetime = .keepAlways
        add(marks)
        guard let path, let trace = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("the trace file is unreadable (\(path ?? "no file= on the probe"))")
            return
        }
        let attachment = XCTAttachment(string: trace)
        attachment.name = "kbm-trace-arrival.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
