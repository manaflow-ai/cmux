import XCTest

/// Input responsiveness on the iPhone, from the app's own trace
/// (`InputLatencyTrace`, `-cmux-mobile-input-latency`;
/// `cmux-next-ios/design/input-latency.md`):
///
/// - keyboard: the key row's keyboard key pressed again and again in a
///   terminal (the `ws-terminal-kbd-toggles` demo): per will-show and
///   will-hide, the main thread's longest iteration and `free_ms`, the time
///   from the notification until the main thread's last iteration of 4 ms and
///   more in the window ended;
/// - terminal typing: one key and Send, 20 times, in the mock terminal: key
///   to its echo presented (`terminal_key_echo`), key to the composer's frame;
/// - chat typing and send: a short message typed and sent, 5 times, in the
///   mock agent chat: key to the composer's frame, send to the host's echo of
///   the prompt (`chat_send_acked`) and to the frame that draws it
///   (`chat_send_visible`).
///
/// Every main-thread iteration of 8 ms and more is a hitch with its sampled
/// stacks in `Documents/input-latency.jsonl`, attached as `input-latency.jsonl`.
/// Each test prints `INPUTLAT {json}`: the flow and the trace's summary
/// (per kind: n, p50, p95, max).
///
/// Run on the fleet:
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=InputLatencyUITests --artifact artifacts/ios-sim/evidence.zip
final class InputLatencyUITests: XCTestCase {
    static let workspaceCount = 150
    static let chatWorkspace = "workspace.row.ws-s0"
    static let terminalWorkspace = "workspace.row.ws-s2"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testKeyboardToggles() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_INPUT_LATENCY"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-kbd-toggles"]
        app.launch()
        XCTAssertTrue(app.textViews["terminal.composer.field"].waitForExistence(timeout: 30), "terminal composer\n\(app.debugDescription)")
        // The demo's toggles take about 25 s: wait for its hides to be counted, then a quiet second.
        _ = waitFor(app, timeout: 90) { ($0["kbd_hide_free"] as? [String: Any]).flatMap { $0["n"] as? Int } ?? 0 >= 8 }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        report("keyboard", app)
    }

    @MainActor
    func testTerminalTyping() throws {
        let app = Self.listApp()
        app.launch()
        open(Self.terminalWorkspace, in: app)
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        field.tap()
        let send = app.buttons["terminal.composer.send"]
        for index in 0 ..< 20 {
            // Printable, distinct from the prompt's own characters where it can be.
            let key = ["~", "q", "z", "#", "%"][index % 5]
            field.typeText(key)
            send.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        _ = waitFor(app, timeout: 10) { ($0["terminal_key_echo"] as? [String: Any]).flatMap { $0["n"] as? Int } ?? 0 >= 10 }
        report("terminal", app)
    }

    @MainActor
    func testChatTypingAndSend() throws {
        let app = Self.listApp()
        app.launch()
        open(Self.chatWorkspace, in: app)
        let field = app.textViews["chat.composer.field"]
        // A chat that opens on a question card folds the composer into "Reply to Claude"
        // (ComposerGrowUpUITests): that button's tap opens the field.
        let reply = app.buttons["Reply to Claude"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !field.exists, !reply.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if !field.exists, reply.exists { reply.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the chat composer\n\(app.debugDescription)")
        field.tap()
        for index in 0 ..< 5 {
            field.typeText("check the link framing \(index)")
            let send = app.buttons["Send"].firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 5), "the chat's Send button\n\(app.debugDescription)")
            send.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            // The running turn folds the composer back into "Reply to Claude"; a tap
            // during that fold can land on the closing button, so tap until it opens.
            let reopen = Date().addingTimeInterval(10)
            while !field.exists, Date() < reopen {
                if reply.exists, reply.isHittable { reply.tap() }
                _ = field.waitForExistence(timeout: 1)
            }
            XCTAssertTrue(field.exists, "the chat composer after send \(index)\n\(app.debugDescription)")
            field.tap()
        }
        _ = waitFor(app, timeout: 10) { ($0["chat_send_visible"] as? [String: Any]).flatMap { $0["n"] as? Int } ?? 0 >= 5 }
        report("chat", app)
    }

    /// The terminal open, cold (a fresh launch per open), first frame drawn
    /// off the layout pass (now) and in it (`-cmux-mobile-term-sync-first-draw`,
    /// before), each idle and with a stream running (`-cmux-mobile-term-fake-codex`),
    /// sides interleaved on one simulator. Per open: tap to the SwiftUI screen's
    /// surface (`term_open_to_surface`), `ghostty_surface_new` (`term_surface_new`),
    /// tap to the first frame (`term_open_first_present`), and the longest
    /// main-thread iteration from the tap on (`term_open_max_iteration`).
    /// Prints `TERMOPEN {json}` per open and `TERMOPEN_TABLE` rows (n, p50, p95, max).
    @MainActor
    func testTerminalOpen() throws {
        let opens = Int(ProcessInfo.processInfo.environment["CMUX_TERM_OPEN_N"] ?? "") ?? 10
        let kinds = ["term_open_to_surface", "term_surface_new", "term_open_first_present", "term_open_max_iteration"]
        let rows: [(name: String, args: [String])] = [
            ("idle/new", []), ("idle/old", ["-cmux-mobile-term-sync-first-draw"]),
            ("stream/new", ["-cmux-mobile-term-fake-codex"]),
            ("stream/old", ["-cmux-mobile-term-fake-codex", "-cmux-mobile-term-sync-first-draw"]),
        ]
        var values: [String: [String: [Double]]] = [:]
        var lines: [String] = []
        for index in 0 ..< opens {
            for row in rows {
                let app = Self.listApp()
                app.launchArguments += row.args
                app.launch()
                open(Self.terminalWorkspace, in: app)
                let done = waitFor(app, timeout: 30) { ($0["term_open_max_iteration"] as? [String: Any]).flatMap { $0["n"] as? Int } ?? 0 >= 1 }
                let probe = summary(app)
                var one: [String: Double] = [:]
                for kind in kinds {
                    if let ms = (probe[kind] as? [String: Any])?["max"] as? Double { one[kind] = ms }
                }
                for (kind, ms) in one { values[row.name, default: [:]][kind, default: []].append(ms) }
                let json = one.sorted { $0.key < $1.key }.map { String(format: "\"%@\":%.1f", $0.key, $0.value) }.joined(separator: ",")
                let line = #"TERMOPEN {"row":"\#(row.name)","i":\#(index),"done":\#(done),\#(json)}"#
                print(line)
                lines.append(line)
                app.terminate()
            }
        }
        // Warm: one process per side, a first open and back (not counted), then
        // `opens` opens and backs: what reopening a terminal costs once its types,
        // shaders and views exist.
        for row in rows {
            let name = row.name.replacingOccurrences(of: "idle/", with: "warm/").replacingOccurrences(of: "stream/", with: "warmstream/")
            let app = Self.listApp()
            app.launchArguments += row.args
            app.launch()
            for index in -1 ..< opens {
                open(Self.terminalWorkspace, in: app)
                let target = index + 2
                let done = waitFor(app, timeout: 30) { ($0["term_open_max_iteration"] as? [String: Any]).flatMap { $0["n"] as? Int } ?? 0 >= target }
                let probe = summary(app)
                var one: [String: Double] = [:]
                for kind in kinds {
                    if let ms = (probe[kind] as? [String: Any])?["last"] as? Double { one[kind] = ms }
                }
                if index >= 0 { for (kind, ms) in one { values[name, default: [:]][kind, default: []].append(ms) } }
                let json = one.sorted { $0.key < $1.key }.map { String(format: "\"%@\":%.1f", $0.key, $0.value) }.joined(separator: ",")
                let line = #"TERMOPEN {"row":"\#(name)","i":\#(index),"done":\#(done),\#(json)}"#
                print(line)
                lines.append(line)
                goBack(in: app)
            }
            app.terminate()
        }
        let allRows = rows.map(\.name) + rows.map { $0.name.replacingOccurrences(of: "idle/", with: "warm/").replacingOccurrences(of: "stream/", with: "warmstream/") }
        for rowName in allRows {
            for kind in kinds {
                let sorted = (values[rowName]?[kind] ?? []).sorted()
                guard !sorted.isEmpty else { continue }
                func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))] }
                let line = String(format: "TERMOPEN_TABLE %@ %@ n=%d p50=%.1f p95=%.1f max=%.1f", rowName, kind, sorted.count, p(0.5), p(0.95), sorted.last ?? 0)
                print(line)
                lines.append(line)
            }
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "terminal-open-table"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(values.isEmpty, "no terminal open was timed")
    }

    // MARK: Helpers

    @MainActor
    static func listApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_INPUT_LATENCY"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = String(workspaceCount)
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux-mobile-term-no-intro"]
        return app
    }

    @MainActor
    private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
    }

    /// Back from a workspace to the list: the navigation bar's back button, else an edge swipe.
    @MainActor
    private func goBack(in app: XCUIApplication) {
        let list = app.buttons[Self.chatWorkspace]
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() } else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        if !list.waitForExistence(timeout: 10) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        XCTAssertTrue(list.waitForExistence(timeout: 10), "back to the list\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func summary(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.staticTexts["debug.input-latency"]
        guard probe.exists, let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @MainActor
    private func waitFor(_ app: XCUIApplication, timeout: TimeInterval, _ done: ([String: Any]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done(summary(app)) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    @MainActor
    private func report(_ flow: String, _ app: XCUIApplication) {
        let probe = app.staticTexts["debug.input-latency"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the app's input latency probe (CMUX_MOBILE_INPUT_LATENCY=1)")
        let line = #"INPUTLAT {"flow":"\#(flow)","summary":\#(probe.label)}"#
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "input-latency-\(flow)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The hitch log with stacks: the simulator's app container is on this Mac's disk.
        if let file = Self.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) {
            let log = XCTAttachment(string: text)
            log.name = "input-latency-\(flow).jsonl"
            log.lifetime = .keepAlways
            add(log)
            for row in text.split(separator: "\n") where row.contains(#""type":"hitch""#) || row.contains(#""type":"window""#) {
                print("INPUTLAT_EVENT \(flow) \(row)")
            }
        } else {
            print("INPUTLAT_EVENT \(flow) trace file not found")
        }
    }

    /// The app's `Documents/input-latency.jsonl`, found in the booted simulator's data containers.
    static func traceFile() -> URL? {
        guard let root = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] else { return nil }
        // The variable names the device's `data` directory; older runtimes named the device directory.
        let candidates = ["Containers/Data/Application", "data/Containers/Data/Application"]
            .map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        guard let base = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let apps = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let files = apps.map { $0.appendingPathComponent("Documents/input-latency.jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }
}
