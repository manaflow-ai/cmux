import QuartzCore
import XCTest

/// Leo, 2026-11-21: "the 'animation' for when the built in keyboard collapses
/// and things shrink is not fast enough. percieved time and time to
/// interactive are not prioritized enough."
///
/// A measurement, not a gate (scripts/measure/ios-keyboard-motion.sh). For
/// each keyboard surface, with the app's keyboard-pin trace on
/// (`-cmux-mobile-kbd-pin-trace`: the keyboard, the focused field and the
/// content behind it as drawn, every display frame), it shows and hides the
/// keyboard 5 times by tap, measures 5 more hides with the key row's keyboard
/// key (where the surface has one), dismisses it 3 times by dragging the content down, and 3
/// more times does each move with the next input right behind it (a key
/// right after a show, a scroll right after a hide: time to interactive).
///
/// Every step is marked as `kbm-mark <CACurrentMediaTime> <surface>
/// <method>.<direction>.<round>`; the trace's `epoch=` line is the app's
/// CACurrentMediaTime at its t=0 (one clock on one host), so the analyzer
/// (scripts/measure/ios_keyboard_motion.py) cuts the trace at the marks. The
/// trace is attached per surface and printed as `kbm-trace <surface> <line>`.
///
/// Between steps the test only sleeps: no accessibility query runs while the
/// keyboard moves, so the frames it measures are the app's own.
final class KeyboardMotionBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// How a surface shows and hides its keyboard.
    private struct Surface {
        var name: String
        var arguments: [String]
        var environment: [String: String] = [:]
        /// The element a tap focuses.
        var field: (XCUIApplication) -> XCUIElement
        /// The key row's Hide Keyboard key, if the surface has one.
        var key: ((XCUIApplication) -> XCUIElement)?
        /// A tap that hides the keyboard; nil: the key row's key hides it.
        var hideByTap: ((XCUIApplication) -> Void)?
        /// Ready to show the keyboard (e.g. pull the search field out).
        var ready: (XCUIApplication) -> Void = { _ in }
        /// The keyboard's keys reach a text view we can watch.
        var types = true
    }

    // -cmux-mobile-input-latency: ios-input-responsiveness's DEBUG main-thread tracer (cmux#49398),
    // writing Documents/input-latency.jsonl ("hitch" rows: iterations of 8 ms or more, with stacks;
    // "window" rows per keyboard show/hide). A build without it ignores the argument.
    private static let base = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-kbd-pin-trace", "-cmux-mobile-input-latency"]

    @MainActor
    func testTerminalShell() throws {
        try bench(Surface(
            name: "terminal",
            arguments: ["-cmux-mobile-demo", "ws-terminal-idle"],
            field: { $0.textViews["terminal.composer.field"] },
            key: { $0.buttons["terminal.key.keyboard"] }))
    }

    /// vim on the alternate screen (the terminal demo's mock Mac answers
    /// resizes as the Mac does; `tuihold` starts vim and leaves it).
    @MainActor
    func testTerminalFullScreenApp() throws {
        try bench(Surface(
            name: "terminal-vim",
            arguments: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded", "-CmuxMobileTerminalDemoMac",
                        "-CmuxMobileTerminalDemoPhases", "tuihold"],
            field: { $0.textViews["terminal.composer.field"] },
            key: { $0.buttons["terminal.key.keyboard"] },
            ready: { app in
                let note = app.staticTexts["debug.terminal-demo"]
                let deadline = Date().addingTimeInterval(40)
                while Date() < deadline, !note.label.hasPrefix("tui.") {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                XCTContext.runActivity(named: "terminal demo: \(note.label)") { _ in }
            }))
    }

    @MainActor
    func testAgentChatComposer() throws {
        try bench(Surface(
            name: "chat",
            arguments: ["-cmux-mobile-demo", "kbd-chat"],
            // The demo opens on a question card, which folds the composer into "Reply to Claude"
            // (ComposerGrowUpUITests): a tap on that button is the tap that shows the keyboard.
            field: { app in
                let text = app.textViews["chat.composer.field"]
                return text.exists ? text : app.buttons["Reply to Claude"].firstMatch
            },
            hideByTap: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }))
    }

    @MainActor
    func testChiefComposer() throws {
        try bench(Surface(
            name: "chief",
            arguments: ["-cmux-mobile-demo", "chief-open"],
            field: { $0.textViews["conversation.composer.text"] },
            hideByTap: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }))
    }

    /// The Workspaces list's pull-down search (WorkspacesListUITests).
    @MainActor
    func testSearchField() throws {
        try bench(Surface(
            name: "search",
            arguments: ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"],
            field: { $0.searchFields.firstMatch },
            hideByTap: { app in
                let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'Cancel' OR label ==[c] 'Close' OR identifier ==[c] 'Cancel'")).firstMatch
                if close.exists { close.tap() } else { app.searchFields.firstMatch.buttons.firstMatch.tap() }
            },
            ready: { app in
                let choose = app.scrollViews["setup.teams.choose"]
                if choose.waitForExistence(timeout: 3) { app.buttons["Manaflow"].tap() }
                guard !app.searchFields.firstMatch.exists || !app.searchFields.firstMatch.isHittable else { return }
                let list = app.collectionViews["workspaces.list"]
                guard list.waitForExistence(timeout: 20) else { return }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                    .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
                _ = app.searchFields.firstMatch.waitForExistence(timeout: 5)
            }))
    }

    // MARK: - The run

    @MainActor
    private func bench(_ surface: Surface) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (k, v) in surface.environment { app.launchEnvironment[k] = v }
        app.launchArguments += Self.base + surface.arguments
        app.launch()

        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "\(surface.name): the keyboard pin probe (-cmux-mobile-kbd-pin-trace)")
        surface.ready(app)
        let field = surface.field(app)
        guard field.waitForExistence(timeout: 30) else {
            XCTFail("\(surface.name): no field to focus\n\(app.debugDescription)")
            dumpTrace(surface, probe)
            return
        }
        // Start from rest (a screen that focuses its field on open).
        if keyboardUp(app) { hide(surface, app, method: "setup") }
        settle()
        attach(app, "\(surface.name)-rest")
        mark(surface, "rest.rest.0")
        settle()

        var notes: [String] = []
        // By tap: a tap on the field shows it, the surface's tap (or its key) hides it.
        for round in 0..<5 {
            showByTap(surface, app, round: round, method: "tap")
            if round == 0 { attach(app, "\(surface.name)-shown") }
            mark(surface, "tap.hide.\(round)")
            if let tap = surface.hideByTap { tap(app) } else { surface.key?(app).tap() }
            settle()
            if keyboardUp(app) {
                notes.append("tap.hide.\(round): the tap left the keyboard up")
                hide(surface, app, method: "reset")
            }
        }
        // By the key row's keyboard key.
        if let key = surface.key {
            for round in 0..<5 {
                showByTap(surface, app, round: round, method: "setup")
                let hideKey = key(app)
                guard hideKey.waitForExistence(timeout: 5) else {
                    XCTFail("\(surface.name): no Hide Keyboard key after focusing the field")
                    continue
                }
                mark(surface, "key.hide.\(round)")
                hideKey.tap()
                settle()
                if keyboardUp(app) {
                    notes.append("key.hide.\(round): the key left the keyboard up")
                    hide(surface, app, method: "reset")
                }
            }
        }
        // Interactive dismissal: drag the content down.
        for round in 0..<3 {
            showByTap(surface, app, round: round, method: "drag")
            mark(surface, "drag.drag.\(round)")
            dragDown(app)
            settle()
            if keyboardUp(app) {
                notes.append("drag.drag.\(round): the drag left the keyboard up")
                hide(surface, app, method: "reset")
            }
        }
        // The floor: the same inputs with no keyboard move, so the harness's own
        // delay between two inputs is measured apart from the keyboard.
        if keyboardUp(app) { hide(surface, app, method: "reset") }
        settle()
        for round in 0..<10 {
            // Hide floor: the scroll that follows a hide, twice, keyboard down.
            surface.ready(app)
            mark(surface, "floor.hide.\(round)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)))
            settle()
        }
        if surface.types {
            showByTap(surface, app, round: 0, method: "floorsetup")
            for round in 0..<10 {
                // Show floor: the field tap and key, keyboard already up.
                mark(surface, "floor.show.\(round)")
                surface.field(app).tap()
                app.typeText("a")
                settle()
                app.typeText(XCUIKeyboardKey.delete.rawValue)
                settle()
            }
            if keyboardUp(app) { hide(surface, app, method: "reset") }
            settle()
        }
        // Time to interactive: the next input right behind each move.
        for round in 0..<10 {
            surface.ready(app)
            mark(surface, "tti.show.\(round)")
            surface.field(app).tap()
            if surface.types {
                // XCUITest types once the app is idle: the key lands when the app takes it.
                app.typeText("a")
                settle()
                app.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            settle()
            mark(surface, "tti.hide.\(round)")
            if let tap = surface.hideByTap { tap(app) } else { surface.key?(app).tap() }
            // A short scroll of the content, right behind it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)))
            settle()
            if keyboardUp(app) { hide(surface, app, method: "reset") }
        }
        mark(surface, "end.end.0")
        settle(0.5)
        attach(app, "\(surface.name)-end")
        for note in notes { XCTContext.runActivity(named: note) { _ in } }
        log("kbm-notes \(surface.name) \(notes.isEmpty ? "-" : notes.joined(separator: "; "))")
        dumpTrace(surface, probe)
    }

    @MainActor
    private func showByTap(_ surface: Surface, _ app: XCUIApplication, round: Int, method: String) {
        surface.ready(app)
        mark(surface, "\(method).show.\(round)")
        surface.field(app).tap()
        settle()
        if !keyboardUp(app) {
            log("kbm-notes \(surface.name) \(method).show.\(round): no keyboard after the tap")
        }
    }

    /// Hides the keyboard by whatever works, outside the measured steps.
    @MainActor
    private func hide(_ surface: Surface, _ app: XCUIApplication, method: String) {
        mark(surface, "\(method).hide.0")
        if let key = surface.key, key(app).exists { key(app).tap() } else if let tap = surface.hideByTap { tap(app) }
        settle()
        if keyboardUp(app) {
            dragDown(app)
            settle()
        }
    }

    @MainActor
    private func dragDown(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor
    private func keyboardUp(_ app: XCUIApplication) -> Bool {
        app.keyboards.firstMatch.exists
    }

    /// Long enough for the keyboard's animation, our motion after it, and a
    /// still stretch before the next step; nothing queries the app meanwhile.
    private func settle(_ seconds: TimeInterval = 1.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func mark(_ surface: Surface, _ label: String) {
        log(String(format: "kbm-mark %.6f %@ %@", CACurrentMediaTime(), surface.name, label))
    }

    /// The marks and notes, printed and kept: dumpTrace attaches them as kbm-marks-SURFACE.txt, since the
    /// simulator step's console export (ui-console.txt) can come back empty.
    private var logged: [String] = []

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    @MainActor
    private func dumpTrace(_ surface: Surface, _ probe: XCUIElement) {
        let line = probe.value as? String ?? ""
        let path = line.split(separator: " ").first { $0.hasPrefix("file=") }
            .map { String($0.dropFirst(5)).replacingOccurrences(of: "%20", with: " ") }
        guard let path, let trace = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("kbm-trace-missing \(surface.name) \(path ?? "-")")
            XCTFail("\(surface.name): the trace file is unreadable (\(path ?? "no file= on the probe"))")
            return
        }
        let attachment = XCTAttachment(string: trace)
        attachment.name = "kbm-trace-\(surface.name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        let marks = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        marks.name = "kbm-marks-\(surface.name).txt"
        marks.lifetime = .keepAlways
        add(marks)
        print("kbm-trace-begin \(surface.name)")
        for row in trace.split(separator: "\n") { print("kbm-trace \(surface.name) \(row)") }
        print("kbm-trace-end \(surface.name)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
