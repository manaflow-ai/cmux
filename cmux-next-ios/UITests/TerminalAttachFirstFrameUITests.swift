import XCTest

/// Leo, 2026-11-17 (softened): "Surely we can just calculate a terminal size
/// and resize whatever needs exceptions, falling back if need be. Plus the
/// loading of everything needs to be FASTER."
///
/// The terminal demo's attach (`-CmuxMobileTerminalDemoAttach`): the phone
/// opens a terminal page onto htop already running on a Mac pane of 120x40,
/// the Mac answering the attach two round trips later (identify, then
/// attach-surface, in series) or one (the grid sent with the attach, the app's
/// plan), and each resize one, of 60 ms (LTE) or 250 ms (a relay). The page
/// traces each step of the attach (``TerminalAttachTrace``) up to the first
/// frame that shows htop at its final grid with nothing held, replayed,
/// queued, settling or unanswered. Each run's trace and each cell's median go
/// in the `attach-first-frame` attachment (the PR's table reads it).
final class TerminalAttachFirstFrameUITests: XCTestCase {
    /// Launches per cell. The cells are (Mac latency, arm): LTE (60 ms) and a
    /// relay (250 ms), each with the grid sent with the attach (one round trip,
    /// the app's plan) and in series (two, as before). The arms alternate launch
    /// by launch in one simulator, so both share one build, worker and warmth.
    private let runs = 6
    private let latencies = [60, 250]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAttachIntoHtopFirstRightFrame() throws {
        XCUIDevice.shared.orientation = .portrait
        var lines: [String] = []
        var first: [String: [Int]] = [:]
        var fromStart: [String: [Int]] = [:]
        var launches = 0
        var reached = 0
        for run in 1...runs {
            for ms in latencies {
                for serial in [false, true] {
                    let cell = "\(ms)ms \(serial ? "series" : "with-attach")"
                    let app = XCUIApplication()
                    app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                    app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                            "-CmuxMobileTerminalDemoAttach", "-CmuxMobileTerminalDemoMac", "-CmuxMobileTerminalDemoMacMs", "\(ms)"]
                    if serial { app.launchArguments.append("-CmuxMobileTerminalDemoAttachSerial") }
                    app.launch()
                    launches += 1
                    let probe = app.staticTexts["debug.terminal-demo"]
                    XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
                    let deadline = Date().addingTimeInterval(20)
                    var label = probe.label
                    while Date() < deadline, !label.hasPrefix("attach.done") {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                        label = probe.label
                    }
                    if launches == 1 {
                        let shot = XCTAttachment(screenshot: app.screenshot())
                        shot.name = "attach-htop"
                        shot.lifetime = .keepAlways
                        add(shot)
                    }
                    lines.append("attach first frame: run \(run) \(cell): \(label)")
                    func value(_ key: String) -> Int? {
                        label.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) }
                    }
                    if let v = value("first"), v >= 0 {
                        reached += 1
                        // Run 1 is the cold launch: kept in the line, left out of the medians.
                        if run > 1 { first[cell, default: []].append(v) }
                    }
                    if run > 1, let v = value("fromstart"), v >= 0 { fromStart[cell, default: []].append(v) }
                    app.terminate()
                }
            }
        }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.isEmpty ? -1 : sorted[sorted.count / 2]
        }
        for ms in latencies {
            for serial in [false, true] {
                let cell = "\(ms)ms \(serial ? "series" : "with-attach")"
                let a = first[cell] ?? [], b = fromStart[cell] ?? []
                lines.append("attach first frame median (warm): \(cell): from view load \(median(a)) ms \(a), from session start \(median(b)) ms \(b)")
            }
        }
        for line in lines { print(line) }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "attach-first-frame"
        attachment.lifetime = .keepAlways
        add(attachment)
        for line in lines.suffix(latencies.count * 2) { XCTContext.runActivity(named: line) { _ in } }
        // Measurement branch only (never merged): a miss is read from the lines, so the step passes and uploads.
        print("attach first frame reached \(reached)/\(launches)")
    }
}
