import QuartzCore
import XCTest

/// snappy-bench, iOS leg. Leo, 2026-11-25: "when you press enter, the stuff should just start
/// playing. we dont need to wait/get blocked by anything on rendering."
///
/// A measurement, not a gate (scripts/measure/ios_snappy.py reads it into `snappy-bench/v1`).
/// With the app's send trace on (`CMUX_MOBILE_LOAD_PROBE=1 CMUX_MOBILE_SEND_TRACE=1`: the chat
/// transcript's visible rows, their role in the turn and their frame, every display frame they
/// changed, and `ev=send` when the composer's send ran), per surface it sends 8 prompts through
/// the real composer (a tap on Send), then (local and cloud) leaves the chat and opens it again
/// 5 times. The surfaces:
/// - `local`: the mock Mac's Claude chat (ws-cmux), as a Mac-hosted chat.
/// - `cloud`: the same with `CMUX_MOBILE_MOCK_LINK=lte` (a 70 ms link's history delay). The
///   simulator CI has no signed-in cloud VM, so its first token is the mock agent's, not a
///   cloud's; the parser labels it.
/// - `duress`: a 1000-turn chat (`CMUX_MOBILE_LIST_SCREEN=chat`, `CMUX_MOBILE_LIST_COUNT=1000`).
///
/// Every step is marked `snap-mark <CACurrentMediaTime> <surface> <label>` (the trace's clock).
/// Between steps the test only sleeps: no accessibility query runs while a turn plays.
final class SnappySendBenchUITests: XCTestCase {
    static let sends = 8
    static let switches = 5

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testLocalSends() throws { try bench("local", environment: [:], switches: true) }

    @MainActor func testCloudLinkSends() throws {
        try bench("cloud", environment: ["CMUX_MOBILE_MOCK_LINK": "lte"], switches: true)
    }

    @MainActor func testDuressThousandTurnSends() throws {
        try bench("duress", environment: [
            "CMUX_MOBILE_LIST_SCREEN": "chat", "CMUX_MOBILE_LIST_COUNT": "1000", "CMUX_MOBILE_LIST_PASSES": "0",
            "CMUX_MOBILE_LIST_LEAVE_NEWEST": "0", "CMUX_MOBILE_LIST_SETTLE": "1",
        ], switches: false)
    }

    // MARK: - The run

    @MainActor
    private func bench(_ surface: String, environment: [String: String], switches: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LOAD_PROBE"] = "1"
        app.launchEnvironment["CMUX_MOBILE_SEND_TRACE"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        let listed = environment["CMUX_MOBILE_LIST_SCREEN"] == nil
        if listed { app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"] }
        app.launch()

        let row = app.buttons["workspace.row.ws-cmux"].firstMatch
        if listed {
            XCTAssertTrue(row.waitForExistence(timeout: 30), "\(surface): the ws-cmux row")
            row.tap()
        }
        let field = Self.field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 90), "\(surface): the chat composer\n\(app.debugDescription)")
        settle(listed ? 3 : 6)
        attach(app, "snappy-\(surface)-open")

        for index in 0..<Self.sends {
            let field = Self.field(app)
            if !app.keyboards.firstMatch.exists, field.exists { field.tap() }
            settle(0.6)
            app.typeText("snappy send \(index)")
            let send = app.buttons["Send"].firstMatch
            guard send.waitForExistence(timeout: 5) else {
                note(surface, "send.\(index): no Send button")
                continue
            }
            settle(0.4)
            if index == 0 { log(String(format: "MOBILEBENCH flow=send-to-first-token event=stimulus t=%.3f", Date().timeIntervalSince1970)) }
            mark(surface, "send.\(index)")
            send.tap()
            settle(4)
            if index == 0 {
                log(String(format: "MOBILEBENCH flow=send-to-first-token event=end t=%.3f", Date().timeIntervalSince1970))
                attach(app, "snappy-\(surface)-sent")
            }
        }
        mark(surface, "sends.end")

        if switches {
            if app.keyboards.firstMatch.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
            settle(1)
            for index in 0..<Self.switches {
                back(app)
                guard row.waitForExistence(timeout: 10) else {
                    note(surface, "switch.\(index): the list never came back")
                    break
                }
                settle(1)
                mark(surface, "switch.\(index)")
                row.tap()
                settle(2.5)
            }
        }
        mark(surface, "end")
        settle(0.5)
        dump(surface)
    }

    @MainActor
    private static func field(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier IN %@", ["chat.composer.field", "chat.composer.card"])).firstMatch
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        settle(1.2)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var logged: [String] = []

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    private func mark(_ surface: String, _ label: String) {
        log(String(format: "snap-mark %.6f %@ %@", CACurrentMediaTime(), surface, label))
    }

    private func note(_ surface: String, _ text: String) {
        log("snap-note \(surface) \(text)")
    }

    /// The marks and the app's send trace, kept as snappy-marks-SURFACE.txt and
    /// snappy-trace-SURFACE.txt.
    @MainActor
    private func dump(_ surface: String) {
        let marks = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        marks.name = "snappy-marks-\(surface).txt"
        marks.lifetime = .keepAlways
        add(marks)
        guard let file = Self.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) else {
            XCTFail("\(surface): no Documents/send-trace.txt in the simulator's app containers")
            return
        }
        let trace = XCTAttachment(string: text)
        trace.name = "snappy-trace-\(surface).txt"
        trace.lifetime = .keepAlways
        add(trace)
    }

    /// The newest `Documents/send-trace.txt` among the simulator's app containers.
    static func traceFile() -> URL? {
        guard let root = ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] else { return nil }
        let candidates = ["Containers/Data/Application", "data/Containers/Data/Application"]
            .map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        guard let base = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let apps = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        let files = apps.map { $0.appendingPathComponent("Documents/send-trace.txt") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
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
