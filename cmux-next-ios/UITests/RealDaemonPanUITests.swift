import Darwin
import XCTest

/// Leo, 2026-11-22 06:04Z: "just off some basic scroll throughs of the tui on
/// my phone, the thing still lags ... why cant you simply scroll through the
/// depiction that was already given?" and 08:05Z: "we should almost always be
/// doing this. always. testing under duress."
///
/// The terminal page attached to a REAL cmux-tui daemon on this Mac: the
/// NIGHTLY's own binary (`verify/real-daemon-pan/daemon.sh`, started from
/// here, since the step script has no real-daemon mode), running a Claude
/// Code-like program (`verify/real-daemon-pan/streamer.py`) that printed
/// 12,000 styled rows and streams a row every 16 ms. One finger pans for 10 s,
/// as in TerminalTUILocalPanUITests, over the primary screen and over a
/// full-screen app on the alternate screen with the mouse asked for. The
/// readout (`TerminalRealDaemonPan`) is attached as text.
final class RealDaemonPanUITests: XCTestCase {
    private static var dir = ""

    override class func setUp() {
        super.setUp()
        dir = "/tmp/cmux-rdp-\(UInt32.random(in: 0..<UInt32.max))"
        _ = spawn(["/bin/bash", daemonScript, "start", dir])
    }

    override class func tearDown() {
        _ = spawn(["/bin/bash", daemonScript, "stop", dir])
        super.tearDown()
    }

    override func setUp() {
        continueAfterFailure = true
    }

    private static var verify: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("verify/real-daemon-pan")
    }

    private static var daemonScript: String { verify.appendingPathComponent("daemon.sh").path }

    /// Starts a host program and waits for it (the simulator's processes are the host's).
    private static func spawn(_ argv: [String]) -> Int32 {
        var pid: pid_t = 0
        let args = argv.map { strdup($0) } + [nil]
        let env = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME=/tmp", "LANG=en_US.UTF-8"].map { strdup($0) } + [nil]
        defer { (args + env).forEach { free($0) } }
        guard posix_spawn(&pid, argv[0], nil, nil, args, env) == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status
    }

    @MainActor func testOneFingerPanOverClaudeCodeOnThePrimaryScreenOfARealDaemonUnderLoad() throws {
        try pan(mode: "primary")
    }

    @MainActor func testOneFingerPanOverAStreamingFullScreenAppWithTheMouseOnARealDaemon() throws {
        try pan(mode: "alt")
    }

    @MainActor
    private func pan(mode: String) throws {
        let dir = Self.dir
        let log = (try? String(contentsOfFile: "\(dir)/daemon.log", encoding: .utf8)) ?? "(no daemon log)"
        let daemonLog = XCTAttachment(string: log)
        daemonLog.name = "real-daemon-pan-daemon-log-\(mode)"
        daemonLog.lifetime = .keepAlways
        add(daemonLog)
        let socket = try XCTUnwrap(try? String(contentsOfFile: "\(dir)/socket", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "the real daemon is up:\n\(log)")
        let version = (try? String(contentsOfFile: "\(dir)/ready", encoding: .utf8)) ?? ""

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_RDP_SOCKET"] = socket
        app.launchEnvironment["CMUX_RDP_DIR"] = dir
        app.launchEnvironment["CMUX_RDP_STREAMER"] = Self.verify.appendingPathComponent("streamer.py").path
        app.launchEnvironment["CMUX_RDP_MODE"] = mode
        app.launchEnvironment["CMUX_RDP_ROWS"] = "12000"
        app.launchEnvironment["CMUX_RDP_PERIOD_MS"] = "16"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        app.launch()
        defer { app.terminate() }

        let prefix = "rdp-\(mode)"
        let probe = app.staticTexts["debug.real-daemon-pan"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the bench's step label\n\(app.debugDescription)")
        var step = ""
        var deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !step.hasPrefix("\(prefix) ready"), !step.contains("error=") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            step = probe.label
        }
        XCTAssertTrue(step.hasPrefix("\(prefix) ready"), "attached to the real daemon with its history: \(step)")

        // 10 s of one finger: drags toward older rows and back, each
        // released moving (a fling), as a thumb reads through a transcript.
        let window = app.windows.firstMatch
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let panEnd = Date().addingTimeInterval(10)
        var drags = 0
        if step.hasPrefix("\(prefix) ready") {
            while Date() < panEnd {
                let older = (drags / 3) % 2 == 0
                (older ? high : low).press(forDuration: 0.02, thenDragTo: older ? low : high,
                                          withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0)
                drags += 1
            }
        }
        let mid = XCTAttachment(screenshot: app.screenshot())
        mid.name = "real-daemon-pan-\(mode)-after-pan"
        mid.lifetime = .keepAlways
        add(mid)

        deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !step.hasPrefix("\(prefix) done"), !step.contains("error=") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            step = probe.label
        }
        let numbers = XCTAttachment(string: "real-daemon-pan \(step) drags=\(drags) daemon=\(version)")
        numbers.name = "real-daemon-pan-\(mode)"
        numbers.lifetime = .keepAlways
        add(numbers)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "real-daemon-pan-\(mode)-end"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(step.hasPrefix("\(prefix) done"), "the bench finished: \(step)")

        let values = Self.values(step)
        XCTAssertTrue(step.contains(mode == "alt" ? "isTUI=true" : "isTUI=false"), "the program is on the screen it uses: \(step)")
        XCTAssertGreaterThan(values["frames"] ?? 0, 60, "frames were measured while the finger panned: \(step)")
        if mode == "alt" {
            XCTAssertGreaterThan(values["wheels"] ?? 0, 0, "the drag sent the app its wheel: \(step)")
        }
    }

    /// `key=N` words of the bench's label.
    private static func values(_ label: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for word in label.split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { out[String(pair[0])] = value }
        }
        return out
    }
}
