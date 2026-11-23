import QuartzCore
import XCTest

/// Leo, 2026-11-23: "when i click the sort of, you know, you know, the Safari button, it's like, okay,
/// the animation is not fast, is not smooth. It's not 120 FPS all the way around. ... it needs to be fast
/// even under load, under extreme load as well."
///
/// A measurement, not a gate (scripts/measure/ios_browser_button.py). With the app's frame trace on
/// (`-cmux-mobile-kbd-pin-trace`: every display frame with `mtb=` main-thread busy ms) and the input-latency
/// tracer (`-cmux-mobile-input-latency`: stacks of main-thread iterations over 8 ms), it opens the
/// mock workspace's Tabs grid (Safari's tab button), picks the browser tab's card (the grid closes into the
/// page), and opens the grid from the page again, `rounds` times. Each tap is marked as
/// `kbm-mark <CACurrentMediaTime> browser <step>.<round>` on the trace's clock (epoch= line).
/// Between taps the test only sleeps, so the frames measured are the app's own.
final class BrowserButtonMotionBenchUITests: XCTestCase {
    private static let rounds = 24

    override func setUp() { continueAfterFailure = true }

    @MainActor
    func testTabsGridAndBrowserCard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-kbd-pin-trace",
                                "-cmux-mobile-input-latency", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the frame trace probe")
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row")
        row.tap()
        settle(2.5)
        let tabs = app.buttons["Tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20), "Tabs button")
        let docs = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'docs' AND label ENDSWITH ', tab'")).firstMatch
        // Warm up once (the first grid builds its cards), outside the marks.
        tabs.tap(); settle(2)
        if docs.waitForExistence(timeout: 10) { docs.tap() }
        settle(2)
        mark("rest.0")
        settle(1)
        for round in 0..<Self.rounds {
            mark("grid.open.\(round)")
            tabs.tap()
            settle()
            mark("card.open.\(round)")
            if docs.exists { docs.tap() } else { log("kbm-notes browser card.open.\(round): no docs card") }
            settle()
        }
        mark("end.0")
        settle(0.5)
        dump(probe)
    }

    private func settle(_ seconds: TimeInterval = 1.8) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var logged: [String] = []

    private func mark(_ label: String) { log(String(format: "kbm-mark %.6f browser %@", CACurrentMediaTime(), label)) }

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    @MainActor
    private func dump(_ probe: XCUIElement) {
        let line = probe.value as? String ?? ""
        let path = line.split(separator: " ").first { $0.hasPrefix("file=") }
            .map { String($0.dropFirst(5)).replacingOccurrences(of: "%20", with: " ") }
        guard let path, let trace = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("the trace file is unreadable (\(path ?? "no file= on the probe"))")
            return
        }
        let t = XCTAttachment(string: trace)
        t.name = "kbm-trace-browser.txt"
        t.lifetime = .keepAlways
        add(t)
        let m = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        m.name = "kbm-marks-browser.txt"
        m.lifetime = .keepAlways
        add(m)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let hitches = try? String(contentsOf: docs.appendingPathComponent("input-latency.jsonl"), encoding: .utf8) {
            let h = XCTAttachment(string: hitches)
            h.name = "kbm-hitches-browser.txt"
            h.lifetime = .keepAlways
            add(h)
        }
    }
}
