import XCTest

/// A profiling target, not a check: the list rig's `feed-ref` case (verify/listperf/final.sh:
/// the Feed with 320 generated events, scrolled down and up) under a UI test, so
/// `scripts/ci/cmux-next-ios-sim.sh test ui=FeedRefProfileUITests profile` records a Time Profiler
/// trace of it. The launch environment is listperf's for that case (CMUX_MOBILE_LIST_* and
/// CMUX_MOBILE_FEED_STRESS, mock auth, exit when done), plus `CMUX_MOBILE_FEED_CELL_TIMING=1`
/// (FeedCellTiming's FEEDCELL lines). The test waits for the rig to exit the app, bounded at 150 s.
///
/// The step keeps no app log for a UI test's simulator, so after the run the test copies the app's
/// `dev.cmux.mobile` log (FRAMELOG and FEEDCELL lines) and its `framelog.jsonl` into keepAlways
/// attachments (ui-attachments/ in the step's artifact). A simulator test runner is a host process:
/// it asks the host's `simctl` for its own device's log. Best effort: a copy that fails is noted in
/// the attachment and never fails the test.
final class FeedRefProfileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFeedRef() {
        let launched = Date()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FRAMELOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "feed"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "320"
        app.launchEnvironment["CMUX_MOBILE_LIST_EXIT_WHEN_DONE"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_CELL_TIMING"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { if app.state != .notRunning { app.terminate() } }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        // The rig scrolls its passes, then exits the app.
        let exited = app.wait(for: .notRunning, timeout: 150)
        print("FEEDREFPROFILE exited=\(exited) state=\(app.state.rawValue)")
        collectAppLog(since: launched)
    }

    /// The app's log and frame log, as attachments.
    private func collectAppLog(since: Date) {
        let env = ProcessInfo.processInfo.environment
        guard let udid = env["SIMULATOR_UDID"] else {
            note("feedref-collect-error", "no SIMULATOR_UDID in the runner's environment")
            return
        }
        let home = env["SIMULATOR_HOST_HOME"] ?? Self.hostHome(from: NSHomeDirectory())
        let dir = NSTemporaryDirectory() + "feedref-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let seconds = Int(Date().timeIntervalSince(since)) + 30
        let devices = "\(home)/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Data/Application"
        let script = """
        set -u
        cd '\(dir)'
        /usr/bin/xcrun simctl spawn '\(udid)' log show --last \(seconds)s --style compact --info \
          --predicate 'subsystem == "dev.cmux.mobile"' > app-log.txt 2> app-log.err
        echo "log show exit $?" >> collect.txt
        for f in '\(devices)'/*/Library/Caches/framelog.jsonl; do
          [ -f "$f" ] && /bin/cp "$f" framelog.jsonl && echo "framelog from $f" >> collect.txt
        done
        date -u '+now %Y-%m-%dT%H:%M:%S' >> collect.txt
        """
        let status = Self.run(["/bin/sh", "-c", script], home: home)
        note("feedref-collect-status", "sh exit \(status); home \(home); udid \(udid)")
        for name in ["collect.txt", "app-log.txt", "app-log.err", "framelog.jsonl"] {
            let path = "\(dir)/\(name)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
            attachment.name = "feedref-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if name == "app-log.txt", let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let lines = text.split(separator: "\n").filter { $0.contains("FEEDCELL") || $0.contains("FRAMELOG") }
                print("FEEDREFPROFILE app log: \(lines.count) FEEDCELL/FRAMELOG lines")
            }
        }
    }

    private func note(_ name: String, _ text: String) {
        print("FEEDREFPROFILE \(name): \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The host's home, from a simulator container path (…/Library/Developer/CoreSimulator/…).
    private static func hostHome(from path: String) -> String {
        guard let range = path.range(of: "/Library/Developer/CoreSimulator/") else { return path }
        return String(path[..<range.lowerBound])
    }

    /// Runs a host command with a plain host environment (not the simulator's), and waits.
    private static func run(_ argv: [String], home: String) -> Int32 {
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(home)"]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, argv[0], nil, nil, &cArgs, &cEnv)
        guard spawned == 0 else { return -1000 - spawned }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status
    }
}
