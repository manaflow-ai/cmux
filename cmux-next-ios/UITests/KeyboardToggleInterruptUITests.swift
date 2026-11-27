import XCTest

/// User report 2026-11-05: toggling the keyboard in quick succession (a second
/// press while the keyboard is still moving) moved the terminal's composer
/// without animation. Every interrupted toggle must carry the composer from
/// where it is on screen, riding the keyboard, never in one frame.
///
/// The `ws-terminal-kbd-toggles` demo presses the key row's keyboard key (the
/// same `toggleKeyboard()` a tap calls) again 0.05 to 0.45 s into the
/// keyboard's hide and its show, then three times in a row. The app's
/// keyboard-pin probe (`-cmux-mobile-kbd-pin-trace`) reads the composer field
/// as drawn on every display frame and counts the frames where it jumped
/// (`fj`), with the keyboard notifications UIKit posted (`evlog`).
final class KeyboardToggleInterruptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testInterruptedKeyboardTogglesAnimateTheComposer() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-kbd-toggles", "-cmux-mobile-kbd-pin-trace"]
        app.launch()

        let field = app.textViews["terminal.composer.field"]
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "terminal composer\n\(app.debugDescription)")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the app's keyboard pin probe (-cmux-mobile-kbd-pin-trace)")
        attach(app, "rest")

        // The demo's toggles take about 25 s; read the probe only between them.
        let deadline = Date().addingTimeInterval(90)
        var line = probe.value as? String ?? ""
        while Date() < deadline, !line.contains("demo=done") {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            line = probe.value as? String ?? ""
        }
        print("kbd-toggles probe: \(line)")
        XCTContext.runActivity(named: "probe: \(line)") { _ in }
        attach(app, "end")
        XCTAssertTrue(line.contains("demo=done"), "the toggle demo finished (\(line))")
        let values = Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        // The app's per-frame trace (keyboard and field as drawn, keyboard
        // notifications, demo steps), for the report's frame plots.
        if let path = values["file"]?.replacingOccurrences(of: "%20", with: " "),
           let trace = try? String(contentsOfFile: path, encoding: .utf8) {
            print("kbd-toggles trace begin")
            for row in trace.split(separator: "\n") where row.contains("demo=") || row.contains("ev=") || row.contains(" fb=") {
                print("kbd-trace \(row)")
            }
            print("kbd-toggles trace end")
            let attachment = XCTAttachment(string: trace)
            attachment.name = "kbd-pin-trace.txt"
            attachment.lifetime = .keepAlways
            add(attachment)
        } else {
            print("kbd-toggles trace unreadable at \(values["file"] ?? "-")")
        }
        let jumps = values["fj"].flatMap { Int($0) }
        XCTAssertNotNil(jumps, "the probe counts jumps (\(line))")
        XCTAssertEqual(jumps, 0, "the composer jumped instead of riding the keyboard: largest \(values["fjmax"] ?? "?") pt at \(values["fjlog"] ?? "?"); keyboard events \(values["evlog"] ?? "?")")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
