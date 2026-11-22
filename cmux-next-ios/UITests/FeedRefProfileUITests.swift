import XCTest

/// A profiling target, not a check: the list rig's `feed-ref` case (verify/listperf/final.sh:
/// the Feed with 320 generated events, scrolled down and up) under a UI test, so
/// `scripts/ci/cmux-next-ios-sim.sh test ui=FeedRefProfileUITests profile` records a Time Profiler
/// trace of it. The launch environment is listperf's for that case (CMUX_MOBILE_LIST_* and
/// CMUX_MOBILE_FEED_STRESS, mock auth, exit when done), plus `CMUX_MOBILE_FEED_CELL_TIMING=1`
/// (FeedCellTiming's FEEDCELL lines). The test holds the app through the first pass down
/// (`feed-down-0`, about 53 s after a 4 s settle), then ends it at 80 s, so the trace stays small enough
/// for xctrace to save (a whole run, four 53 s windows, recorded 1.7 GB on a busy host).
///
/// The step keeps no app log for a UI test's simulator, so after the run the test copies the app's
/// `dev.cmux.mobile` log (FRAMELOG and FEEDCELL lines) and its `framelog.jsonl` into keepAlways
/// attachments (ui-attachments/ in the step's artifact). The runner lives in the simulator's
/// bootstrap, so it runs the simulator runtime's own `log` (`$SIMULATOR_ROOT/usr/bin/log`, with the
/// runner's environment) against the simulator's logd; the host's `simctl` cannot reach
/// CoreSimulatorService from there. Best effort: a copy that fails is noted and never fails the test.
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
        // Nothing touches the app's accessibility tree while the rig runs: a query (an element's
        // `waitForExistence`, `app.wait(for:)`) makes XCTest snapshot it on the app's main thread,
        // 100-300 ms each on this list, which would land in the frames this profile reads. So the
        // test only waits, a fixed 80 s: feed-down-0 starts about 4 s after the Feed opens and lasts
        // about 53 s; the rig's later passes are not needed and only grow the trace.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the rig's first pass down")], timeout: 80)
        print("FEEDREFPROFILE after 80 s: state=\(app.state.rawValue)")
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
        // The simulator's own `log`, with the runner's (simulator) environment, so it reaches the
        // simulator's logd.
        let simLog = (env["SIMULATOR_ROOT"] ?? "") + "/usr/bin/log"
        let logStatus = Self.run([simLog, "show", "--last", "\(seconds)s", "--style", "compact", "--info",
                                  "--predicate", "subsystem == \"dev.cmux.mobile\""],
                                 environment: env.map { "\($0.key)=\($0.value)" },
                                 stdout: "\(dir)/app-log.txt", stderr: "\(dir)/app-log.err")
        // The frame log, by a host shell with a plain host environment (this worked on the first run).
        let devices = "\(home)/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Data/Application"
        let script = """
        cd '\(dir)'
        for f in '\(devices)'/*/Library/Caches/framelog.jsonl; do
          [ -f "$f" ] && /bin/cp "$f" framelog.jsonl && echo "framelog from $f" >> collect.txt
        done
        date -u '+now %Y-%m-%dT%H:%M:%S' >> collect.txt
        """
        let shStatus = Self.run(["/bin/sh", "-c", script], environment: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(home)"])
        note("feedref-collect-status", "sim log \(simLog) exit \(logStatus); sh exit \(shStatus); home \(home); udid \(udid)")
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

    /// Runs a command with the given environment, its output to files, and waits.
    private static func run(_ argv: [String], environment: [String], stdout: String? = nil, stderr: String? = nil) -> Int32 {
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdout { posix_spawn_file_actions_addopen(&actions, 1, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        if let stderr { posix_spawn_file_actions_addopen(&actions, 2, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, argv[0], &actions, nil, &cArgs, &cEnv)
        guard spawned == 0 else { return -1000 - spawned }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status
    }
}
