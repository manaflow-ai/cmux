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
        let rows = try runZoomCycles(label: "idle", environment: [:])
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
        XCTAssertTrue(rowFailures.isEmpty, "the composer row rides every zoom:\n" + rowFailures.joined(separator: "\n"))
    }

    /// The grid a person has (Leo, 2026-11-25: "the transitioning into and out of
    /// the iOS grid is still slow"): 27 tabs, 25 of them terminals, every one
    /// with 2,000 lines of scrollback and a line streaming in every 70 ms
    /// (`CMUX_MOBILE_MOCK_TABS`, `CMUX_MOBILE_MOCK_TERMINAL_STREAM`), and the
    /// main-thread tracer on (`-cmux-mobile-input-latency`): per zoom, the
    /// main thread's longest iteration and its iterations of 4 ms or more
    /// inside the zoom (`TABZOOM_MAIN`), and the views re-run while it moved
    /// (`TABZOOM_WORK`).
    @MainActor
    func testTabsButtonZoomManyLiveTerminals() throws {
        let rows = try runZoomCycles(label: "many", environment: [
            "CMUX_MOBILE_MOCK_TABS": "\(Self.stressTabs)",
            "CMUX_MOBILE_MOCK_TERMINAL_STREAM": "1",
        ], arguments: ["-cmux-mobile-input-latency"])
        var hitches: [(t: Double, ms: Double, top: String)] = []
        if let file = InputLatencyUITests.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) {
            let latency = XCTAttachment(string: text)
            latency.name = "tabzoom-latency.jsonl"
            latency.lifetime = .keepAlways
            add(latency)
            for line in text.split(separator: "\n") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      o["type"] as? String == "hitch", let t = (o["t"] as? NSNumber)?.doubleValue,
                      let ms = (o["ms"] as? NSNumber)?.doubleValue else { continue }
                hitches.append((t, ms, Self.topFrames(o["stacks"])))
            }
        } else {
            print("TABZOOM_MAIN missing input-latency.jsonl")
        }
        var budget: [String] = []
        for (i, row) in rows.enumerated() {
            let toGrid = (row["toOverview"] as? Bool) == true
            let start = (row["startMs"] as? NSNumber)?.doubleValue ?? 0
            let end = (row["endMs"] as? NSNumber)?.doubleValue ?? 0
            // An iteration that started inside the zoom, or the one running when it started.
            let mine = hitches.filter { $0.t >= start - 50 && $0.t <= end && $0.t + $0.ms >= start }
            let line = String(format: "TABZOOM_MAIN zoom=%d direction=%@ main_max_ms=%.1f main_busy_ms=%.1f iterations_4ms=%d",
                              i, toGrid ? "to_grid" : "to_page", mine.map { $0.ms }.max() ?? 0,
                              mine.map { $0.ms }.reduce(0, +), mine.count)
            print(line + (mine.max { $0.ms < $1.ms }.map { " worst_at=\($0.top)" } ?? ""))
            let work = row["work"] as? [String: Any]
            let frames = (row["frames"] as? NSNumber)?.intValue ?? 0
            let screen = (work?["screen"] as? NSNumber)?.intValue ?? -1
            let grid = (work?["grid"] as? NSNumber)?.intValue ?? -1
            let cards = (work?["cards"] as? NSNumber)?.intValue ?? -1
            let workLine = "TABZOOM_WORK zoom=\(i) direction=\(toGrid ? "to_grid" : "to_page") frames=\(frames) screen=\(screen) grid=\(grid) cards=\(cards)"
                + " gate_compared=\(work?["gateCompared"] ?? "-") gate_equal=\(work?["gateEqual"] ?? "-") gate_pass=\(work?["gatePass"] ?? "-")"
            print(workLine)
            // Host-independent budget: the grid and its cards are built once
            // for a zoom (as it starts), never again per frame, whatever the
            // tab count. A per-frame re-run is work times the tabs per frame.
            if grid < 0 || grid > Self.gridBodiesPerZoom || cards > Self.cardBodiesPerZoom { budget.append(workLine) }
        }
        let attachment = XCTAttachment(string: hitches.map { String(format: "%.1f %.1f %@", $0.t, $0.ms, $0.top) }.joined(separator: "\n"))
        attachment.name = "tabzoom-hitches.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(budget.isEmpty, "the grid re-ran during the zoom (at most \(Self.gridBodiesPerZoom) grid and "
                      + "\(Self.cardBodiesPerZoom) card bodies a zoom):\n" + budget.joined(separator: "\n"))
    }

    /// Terminals added to the demo workspace's three tabs.
    static let stressTabs = 24
    /// The zoom's work budget (`TABZOOM_WORK`), the same on any host.
    static let gridBodiesPerZoom = 3
    static let cardBodiesPerZoom = 2 * (stressTabs + 3)

    /// The first frames of a hitch's stacks that are not the system's.
    static func topFrames(_ stacks: Any?) -> String {
        guard let stacks = stacks as? [[String]], let first = stacks.first else { return "-" }
        let system = ["libsystem", "libdispatch", "libobjc", "libswift", "dyld", "CoreFoundation", "UIKitCore", "QuartzCore",
                      "SwiftUI", "AttributeGraph", "GraphicsServices", "0x"]
        let own = first.filter { frame in !system.contains { frame.contains($0) } }
        return (own.isEmpty ? Array(first.prefix(3)) : Array(own.prefix(3))).joined(separator: "<").replacingOccurrences(of: " ", with: "_")
    }

    /// Opens the demo terminal, then `cycles` times: the tabs button (page to
    /// grid), a pause, Done (grid to page), a pause. Prints and attaches the
    /// app's frame log; returns its rows.
    @MainActor
    private func runZoomCycles(label: String, environment: [String: String], arguments: [String] = []) throws -> [[String: Any]] {
        // A previous run's log on this simulator is not this run's.
        if let old = Self.logFile() { try? FileManager.default.removeItem(at: old) }
        if let old = InputLatencyUITests.traceFile() { try? FileManager.default.removeItem(at: old) }
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_TABS_FRAME_LOG"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"] + arguments
        app.launch()

        // The terminal page is up once its composer shows (the key row only
        // shows with the keyboard up since the composer bar, #53471).
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal's composer\n\(app.debugDescription)")
        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "the tabs button\n\(app.debugDescription)")
        let screen = app.windows.firstMatch.frame
        func done() -> XCUIElement? {
            let all = app.buttons.matching(NSPredicate(format: "label == 'Done'")).allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
            // The grid's bottom bar Done first; any hittable Done if the grid's bar moved.
            return all.first { $0.frame.minY > screen.height * 0.8 } ?? all.first
        }
        // A quiet moment after launch, so the first zoom is not measured against launch work.
        RunLoop.current.run(until: Date().addingTimeInterval(environment.isEmpty ? 1.5 : 4))

        for cycle in 0 ..< Self.cycles {
            tabs.tap()
            var bar: XCUIElement?
            let deadline = Date().addingTimeInterval(10)
            while bar == nil, Date() < deadline {
                bar = done()
                if bar == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            }
            guard let bar else {
                XCTFail("the grid's Done, cycle \(cycle)\n\(app.debugDescription)")
                return []
            }
            if cycle == 0 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "tabzoom-\(label)-grid"
                shot.lifetime = .keepAlways
                add(shot)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            // The glass bar can report Done with the whole bar's frame (38..364),
            // whose center is the "N Tabs" title: tap Done's own circle, 24 pt in
            // from the frame's trailing edge (TabOverview's bottom bar).
            let frame = bar.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY)).tap()
            XCTAssertTrue(tabs.waitForExistence(timeout: 10) && field.waitForExistence(timeout: 10),
                          "back on the terminal page, cycle \(cycle)\n\(app.debugDescription)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }

        guard let file = Self.logFile(), let text = try? String(contentsOf: file, encoding: .utf8) else {
            XCTFail("the app's Documents/tabs-zoom-frames.jsonl (CMUX_TABS_FRAME_LOG=1, a DEBUG build)")
            return []
        }
        let rows = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            print("TABZOOM_FRAMES \(line)")
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "tabs-zoom-frames-\(label).jsonl"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(rows.count, Self.cycles * 2 - 1, "one log row per zoom\n\(text)")
        for direction in [true, false] {
            let mine = rows.filter { ($0["toOverview"] as? Bool) == direction }
            func doubles(_ key: String) -> [Double] { mine.compactMap { ($0[key] as? NSNumber)?.doubleValue } }
            func ints(_ key: String) -> Int { mine.compactMap { ($0[key] as? NSNumber)?.intValue }.reduce(0, +) }
            let frames = ints("frames")
            let line = String(format: "TABZOOM_SUMMARY scene=%@ direction=%@ zooms=%d frames=%d duration_ms_max=%.1f worst_ms=%.1f first_frame_ms_max=%.1f over_8_3ms=%d over_16_7ms=%d max_fps=%d",
                              label, direction ? "to_grid" : "to_page", mine.count, frames, doubles("durationMs").max() ?? 0,
                              doubles("worstMs").max() ?? 0, doubles("firstFrameMs").max() ?? 0, ints("over8ms"), ints("over16ms"),
                              mine.compactMap { ($0["maxFPS"] as? NSNumber)?.intValue }.max() ?? 0)
            print(line)
            let summary = XCTAttachment(string: line)
            summary.name = "tabzoom-summary-\(label)-\(direction ? "to-grid" : "to-page")"
            summary.lifetime = .keepAlways
            add(summary)
        }
        return rows
    }

    /// The composer focused and the keyboard up: the bar sits at the top (#52370), so the
    /// keyboard never covers the tabs button. One tap on it still zooms to the grid, the
    /// keyboard goes down with the page, and Done comes back to the terminal.
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
        XCTAssertTrue(tabs.exists && tabs.isHittable, "the top bar's tabs button stays clear of the keyboard\n\(app.debugDescription)")
        tabs.tap()
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "one tap on Tabs reaches the grid with the keyboard up\n\(app.debugDescription)")
        let grid = XCTAttachment(screenshot: app.screenshot())
        grid.name = "keyboard-up-grid"
        grid.lifetime = .keepAlways
        add(grid)
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
