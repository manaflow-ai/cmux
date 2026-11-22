import XCTest

/// A profiling target, not a check: the list rig's Workspaces live cases (verify/listperf/final.sh)
/// under a UI test, so `scripts/ci/cmux-next-ios-sim.sh test ui=ListLiveProfileUITests/<method> profile`
/// records a Time Profiler trace of the Workspaces list taking live Mac updates while the rig scrolls.
/// - `testWorkspaces200Live4`: `ws-200-live4` (200 workspaces, 4 Hz).
/// - `testWorkspaces500Live8`: `ws-500-live8` (500 workspaces, 8 Hz).
/// The launch environment is listperf's (CMUX_MOBILE_LIST_*, mock auth, frame log, exit when done).
///
/// Nothing touches the app's accessibility tree while the rig runs: a query (`waitForExistence`,
/// `app.wait(for:)`) makes XCTest snapshot it on the app's main thread, 100-300 ms each, which would
/// land in the frames the profile reads. The test waits a fixed 75 s (the rig settles 4 s, scrolls
/// its two passes and exits the app), then copies the app's `dev.cmux.mobile` log and its
/// `framelog.jsonl` into keepAlways attachments (ui-attachments/ in the step's artifact).
final class ListLiveProfileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testWorkspaces200Live4() { run(count: 200, hz: 4) }
    @MainActor func testWorkspaces500Live8() { run(count: 500, hz: 8) }

    @MainActor
    private func run(count: Int, hz: Int) {
        let launched = Date()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FRAMELOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = "\(hz)"
        app.launchEnvironment["CMUX_MOBILE_LIST_EXIT_WHEN_DONE"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { if app.state != .notRunning { app.terminate() } }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the rig's passes")], timeout: 75)
        print("LISTLIVEPROFILE ws-\(count)-live\(hz) after 75 s: state=\(app.state.rawValue)")
        collectAppLog(since: launched)
    }

    /// The app's log and frame log, as attachments.
    private func collectAppLog(since: Date) {
        let env = ProcessInfo.processInfo.environment
        guard let udid = env["SIMULATOR_UDID"] else {
            note("listlive-collect-error", "no SIMULATOR_UDID in the runner's environment")
            return
        }
        let home = env["SIMULATOR_HOST_HOME"] ?? Self.hostHome(from: NSHomeDirectory())
        let dir = NSTemporaryDirectory() + "listlive-\(UUID().uuidString)"
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
        note("listlive-collect-status", "sim log \(simLog) exit \(logStatus); sh exit \(shStatus); home \(home); udid \(udid)")
        for name in ["collect.txt", "app-log.txt", "app-log.err", "framelog.jsonl"] {
            let path = "\(dir)/\(name)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
            attachment.name = "listlive-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if name == "app-log.txt", let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let lines = text.split(separator: "\n").filter { $0.contains("FRAMELOG") }
                print("LISTLIVEPROFILE app log: \(lines.count) FRAMELOG lines")
            }
        }
    }

    private func note(_ name: String, _ text: String) {
        print("LISTLIVEPROFILE \(name): \(text)")
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
