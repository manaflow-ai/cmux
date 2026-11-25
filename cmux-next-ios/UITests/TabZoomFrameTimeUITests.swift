import XCTest

/// Frame times of the tabs button's zoom, from a terminal page to the tab
/// grid and back (Done), from the app's own CADisplayLink log
/// (`CMUX_TABS_FRAME_LOG=1`, CmuxTabsKit `TabZoomDriver`): per zoom, the tap
/// to the first frame it draws, the worst frame, and the frames longer than
/// 8.3 ms (120 Hz) and 16.7 ms (60 Hz). Each test prints one `TABZOOM_FRAMES`
/// line per zoom and a `TABZOOM_SUMMARY` line; run before and after a change
/// to the zoom on the same harness and compare.
///
/// Leo, 2026-11-22: "the button clicking is not smooth. it's not 120fps."
///
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=TabZoomFrameTimeUITests --arg video --artifact artifacts/ios-sim/evidence.zip
final class TabZoomFrameTimeUITests: XCTestCase {
    static let cycles = 6

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTabsButtonZoomFrameTimes() throws {
        // A previous run's log on this simulator is not this run's.
        if let old = Self.logFile() { try? FileManager.default.removeItem(at: old) }
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_TABS_FRAME_LOG"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()

        let escape = app.buttons["terminal.key.escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 30), "the terminal's key row\n\(app.debugDescription)")
        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "the tabs button\n\(app.debugDescription)")
        let screen = app.windows.firstMatch.frame
        func done() -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex.first { e in
                e.exists && e.isHittable && e.frame.minY > screen.height * 0.8
            }
        }
        // A quiet second after launch, so the first zoom is not measured against launch work.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        for cycle in 0 ..< Self.cycles {
            tabs.tap()
            var bar: XCUIElement?
            let deadline = Date().addingTimeInterval(10)
            while bar == nil, Date() < deadline {
                bar = done()
                if bar == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            }
            guard let bar else { return XCTFail("the grid's Done, cycle \(cycle)\n\(app.debugDescription)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            // The glass bar can report Done with the whole bar's frame (38..364),
            // whose center is the "N Tabs" title: tap Done's own circle, 24 pt in
            // from the frame's trailing edge (TabOverview's bottom bar).
            let frame = bar.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY)).tap()
            XCTAssertTrue(tabs.waitForExistence(timeout: 10) && escape.waitForExistence(timeout: 10),
                          "back on the terminal page, cycle \(cycle)\n\(app.debugDescription)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }

        guard let file = Self.logFile(), let text = try? String(contentsOf: file, encoding: .utf8) else {
            return XCTFail("the app's Documents/tabs-zoom-frames.jsonl (CMUX_TABS_FRAME_LOG=1, a DEBUG build)")
        }
        let rows = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            print("TABZOOM_FRAMES \(line)")
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "tabs-zoom-frames.jsonl"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(rows.count, Self.cycles * 2 - 1, "one log row per zoom\n\(text)")
        // Leo, 2026-11-22: "the layout shift when i go from terminal to that view via
        // that button is crazy because it has to tuck away the composer area". The
        // composer row rides every zoom: drawn on its first frame, part-faded on the
        // way, scaled with the page (AccessoryTrace, `row` in each log row).
        var rowFailures: [String] = []
        for (i, row) in rows.enumerated() {
            let trace = row["row"] as? [String: Any]
            let line = "TABZOOM_ROW zoom=\(i) direction=\((row["toOverview"] as? Bool) == true ? "to_grid" : "to_page") "
                + (trace.map { t in ["samples", "firstOpacity", "lastOpacity", "midFades", "firstScale", "lastScale", "ridesZoom"]
                    .map { "\($0)=\(t[$0] ?? "nil")" }.joined(separator: " ") } ?? "row=nil")
            print(line)
            if trace?["ridesZoom"] as? Bool != true { rowFailures.append(line) }
        }
        for direction in [true, false] {
            let mine = rows.filter { ($0["toOverview"] as? Bool) == direction }
            func doubles(_ key: String) -> [Double] { mine.compactMap { ($0[key] as? NSNumber)?.doubleValue } }
            func ints(_ key: String) -> Int { mine.compactMap { ($0[key] as? NSNumber)?.intValue }.reduce(0, +) }
            let frames = ints("frames")
            let line = String(format: "TABZOOM_SUMMARY direction=%@ zooms=%d frames=%d worst_ms=%.1f first_frame_ms_max=%.1f over_8_3ms=%d over_16_7ms=%d max_fps=%d",
                              direction ? "to_grid" : "to_page", mine.count, frames, doubles("worstMs").max() ?? 0,
                              doubles("firstFrameMs").max() ?? 0, ints("over8ms"), ints("over16ms"),
                              mine.compactMap { ($0["maxFPS"] as? NSNumber)?.intValue }.max() ?? 0)
            print(line)
            let summary = XCTAttachment(string: line)
            summary.name = "tabzoom-summary-\(direction ? "to-grid" : "to-page")"
            summary.lifetime = .keepAlways
            add(summary)
        }
        XCTAssertTrue(rowFailures.isEmpty, "the composer row rides every zoom:\n" + rowFailures.joined(separator: "\n"))
    }

    /// The composer focused and the keyboard up: the keyboard covers the
    /// toolbar, so the tabs button can't start a zoom while it is up and the
    /// keyboard never leaves mid-zoom from that button. Dropping the keyboard
    /// brings the button back, and the zoom then runs as in the test above.
    @MainActor
    func testTabsButtonWithKeyboardUp() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal's composer\n\(app.debugDescription)")
        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15) && tabs.isHittable, "the tabs button before the keyboard")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "keyboard up")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "keyboard-up"
        shown.lifetime = .keepAlways
        add(shown)
        XCTAssertFalse(tabs.exists && tabs.isHittable, "the keyboard covers the tabs button\n\(app.debugDescription)")
    }

    /// The app's `Documents/tabs-zoom-frames.jsonl`, found in the booted simulator's data containers.
    static func logFile() -> URL? {
        guard let root = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] else { return nil }
        let candidates = ["Containers/Data/Application", "data/Containers/Data/Application"]
            .map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        guard let base = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let apps = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        let files = apps.map { $0.appendingPathComponent("Documents/tabs-zoom-frames.jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }
}
