import QuartzCore
import XCTest

/// Leo, 2026-11-21: "when i was talkin ab the built in keyboard of ios / it's
/// like / the thing drops / the display isn't immediately motherf***ing
/// responsive."
///
/// KeyboardMotionBenchUITests' second input comes from XCUITest, whose runner
/// waits for the app to go idle before it synthesizes an event, so its time to
/// interactive carried 0.8-1.4 s of runner wait. Here XCUITest only moves the
/// keyboard (a tap on the field, the surface's hide); the second input comes
/// from inside the app (`-cmux-mobile-kbd-inject`, KeyboardInputInjector) on
/// the trace's clock:
///
/// - `slide`: a touch where the user sees the field (show) or the content
///   (hide, a short drag) at willShow/willHide + 100, 200, 300 and 900 ms, in
///   turn per direction; 80 moves each way, 20 per offset.
/// - `tti`: a key (show) or the drag (hide) on the first frame the keyboard is
///   drawn at its end; 20 moves each way.
///
/// The marks (`kbm-mark <CACurrentMediaTime> <surface> <step>`) and the trace
/// are attached as in KeyboardMotionBenchUITests; the analyzer is
/// scripts/measure/ios_keyboard_inject.py.
final class KeyboardInjectBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private struct Surface {
        var name: String
        var arguments: [String]
        var field: (XCUIApplication) -> XCUIElement
        var key: ((XCUIApplication) -> XCUIElement)?
        var hideByTap: ((XCUIApplication) -> Void)?
    }

    private static let base = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-kbd-pin-trace"]

    @MainActor private static var terminal: Surface { Surface(
        name: "terminal",
        arguments: ["-cmux-mobile-demo", "ws-terminal-idle"],
        field: { $0.textViews["terminal.composer.field"] },
        key: { $0.buttons["terminal.key.keyboard"] }) }

    @MainActor private static var chat: Surface { Surface(
        name: "chat",
        arguments: ["-cmux-mobile-demo", "kbd-chat"],
        field: { app in
            let text = app.textViews["chat.composer.field"]
            return text.exists ? text : app.buttons["Reply to Claude"].firstMatch
        },
        hideByTap: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }) }

    @MainActor private static var chief: Surface { Surface(
        name: "chief",
        arguments: ["-cmux-mobile-demo", "chief-open"],
        field: { $0.textViews["conversation.composer.text"] },
        hideByTap: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }) }

    @MainActor func testSlideTerminal() throws { try run(Self.terminal, mode: "slide", rounds: 80) }
    @MainActor func testSlideChat() throws { try run(Self.chat, mode: "slide", rounds: 80) }
    @MainActor func testSlideChief() throws { try run(Self.chief, mode: "slide", rounds: 80) }
    @MainActor func testTTITerminal() throws { try run(Self.terminal, mode: "tti", rounds: 20) }
    @MainActor func testTTIChat() throws { try run(Self.chat, mode: "tti", rounds: 20) }
    @MainActor func testTTIChief() throws { try run(Self.chief, mode: "tti", rounds: 20) }

    @MainActor
    private func run(_ surface: Surface, mode: String, rounds: Int) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += Self.base + surface.arguments + ["-cmux-mobile-kbd-inject", mode]
        app.launch()
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "\(surface.name): the keyboard pin probe")
        // The trace's path, read now: a crash of the app's injected touch still leaves the file.
        let path = (probe.value as? String ?? "").split(separator: " ").first { $0.hasPrefix("file=") }
            .map { String($0.dropFirst(5)).replacingOccurrences(of: "%20", with: " ") }
        let name = "\(surface.name)-\(mode)"
        guard surface.field(app).waitForExistence(timeout: 30) else {
            XCTFail("\(name): no field to focus")
            attachTrace(name, path)
            return
        }
        if keyboardUp(app) { hide(surface, app, label: "setup.hide.0", name: name) }
        settle()
        var notes: [String] = []
        for round in 0..<rounds {
            mark(name, "\(mode).show.\(round)")
            surface.field(app).tap()
            settle()
            if !keyboardUp(app) { notes.append("\(mode).show.\(round): no keyboard") }
            mark(name, "\(mode).hide.\(round)")
            if let tap = surface.hideByTap { tap(app) } else { surface.key?(app).tap() }
            settle()
            if keyboardUp(app) {
                notes.append("\(mode).hide.\(round): the keyboard stayed up")
                hide(surface, app, label: "reset.hide.\(round)", name: name)
            }
        }
        mark(name, "end.end.0")
        settle(0.5)
        log("kbm-notes \(name) \(notes.isEmpty ? "-" : notes.joined(separator: "; "))")
        attachTrace(name, path)
    }

    @MainActor
    private func hide(_ surface: Surface, _ app: XCUIApplication, label: String, name: String) {
        mark(name, label)
        if let key = surface.key, key(app).exists { key(app).tap() } else { surface.hideByTap?(app) }
        settle()
        if keyboardUp(app) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            settle()
        }
    }

    @MainActor
    private func keyboardUp(_ app: XCUIApplication) -> Bool { app.keyboards.firstMatch.exists }

    /// Longer than the latest injection (900 ms after the keyboard's notification) and its drag.
    private func settle(_ seconds: TimeInterval = 1.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var logged: [String] = []

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    private func mark(_ name: String, _ label: String) {
        log(String(format: "kbm-mark %.6f %@ %@", CACurrentMediaTime(), name, label))
    }

    private func attachTrace(_ name: String, _ path: String?) {
        let marks = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        marks.name = "kbm-marks-\(name).txt"
        marks.lifetime = .keepAlways
        add(marks)
        guard let path, let trace = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(name): the trace file is unreadable (\(path ?? "no file= on the probe"))")
            return
        }
        let attachment = XCTAttachment(string: trace)
        attachment.name = "kbm-trace-\(name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
