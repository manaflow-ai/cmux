@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Darwin
import Foundation
import Testing

/// Where a 512-workspace classic import spends its time early in the run and
/// late in it, for the app process and its daemon: `/usr/bin/sample` over the
/// same window length at both points, plus each process's CPU share. A cost
/// that grows with the workspaces already made shows as a stack that is heavier
/// late than early. Prints a profile and checks nothing; runs only when a run names
/// it by name: `CMUX_SWIFT_TEST_SUITES=ClassicUpgradeHugeProfileTests` on a fleet run (``SelfSampler``).
@MainActor @Suite(.serialized, .timeLimit(.minutes(15)),
                  .enabled(if: ProcessInfo.processInfo.environment["CMUX_SWIFT_TEST_SUITES"]?.contains("ClassicUpgradeHugeProfileTests") == true
                               && SameTreeDaemonBinary.url != nil,
                           "name it in CMUX_SWIFT_TEST_SUITES on a fleet run"))
struct ClassicUpgradeHugeProfileTests {
    static let window = 20

    /// The simulation the phases share.
    private static var sim: ClassicUpgradeSimulator?
    private static var daemon: pid_t?

    /// Phases, each under the suite watchdog's 180 s: 0 launches and profiles early, 1 waits
    /// (up to 150 s) for 250 workspaces made, 2 profiles late and ends the run.
    @Test(arguments: [0, 1, 2])
    func earlyAndLateImportProfiles(_ phase: Int) async throws {
        switch phase {
        case 0:
            let mac = try ClassicUpgradeSimulator.Mac()
            try mac.save(ClassicUpgradeProfile.huge)
            let sim = try ClassicUpgradeSimulator(mac: mac)
            Self.sim = sim
            let launch = await sim.launch(deadline: .seconds(25))
            guard sim.services.onboarding.classicMigrationRun != nil else {
                Issue.record("no migration run: \(String(describing: launch.failure))")
                return
            }
            Self.daemon = Self.daemonPID(under: mac.root.path)
            print("CLASSIC-PROFILE daemon_pid=\(Self.daemon.map(String.init) ?? "none") \(Self.daemonCommands())")
            await Self.profile("early", sim: sim, daemon: Self.daemon)
        case 1:
            let sim = try #require(Self.sim)
            let clock = ContinuousClock()
            let until = clock.now + .seconds(150)
            while clock.now < until, sim.made().count < 250 { try? await Task.sleep(for: .seconds(1)) }
            print("CLASSIC-PROFILE waited made=\(sim.made().count)")
        default:
            let sim = try #require(Self.sim)
            defer { Self.sim = nil }
            await Self.profile("late", sim: sim, daemon: Self.daemon)
            sim.services.onboarding.classicMigrationRun?.cancel()
            await sim.shutdown()
        }
    }

    /// Samples this process and the daemon for ``window`` seconds, then prints the
    /// rate of workspaces made, each process's CPU share and their heaviest stacks.
    private static func profile(_ label: String, sim: ClassicUpgradeSimulator, daemon: pid_t?) async {
        let madeBefore = sim.made().count
        let appCPU = cpuSeconds(getpid()), daemonCPU = daemon.map(cpuSeconds)
        let daemonSample = daemon.map { ExternalSample(pid: $0, seconds: window) }
        let (report, _) = (try? await SelfSampler.run(name: "classic-\(label)", seconds: window) { _ in
            try await Task.sleep(for: .seconds(window))
        }) ?? (nil, ())
        let made = sim.made().count - madeBefore
        let appShare = (cpuSeconds(getpid()) - appCPU) / Double(window)
        let daemonShare = daemon.flatMap { pid in daemonCPU.map { (cpuSeconds(pid) - $0) / Double(window) } } ?? -1
        print(String(format: "CLASSIC-PROFILE %@ made_before=%d made_in_window=%d per_workspace=%.0fms app_cpu=%.2f daemon_cpu=%.2f",
                     label, madeBefore, made, made == 0 ? 0 : Double(window) * 1000 / Double(made), appShare, daemonShare))
        for controller in sim.services.windows.controllers {
            let list = controller.sidebar.container.sidebarView.list
            print("CLASSIC-PROFILE \(label) sidebar realized=\(list.rowViews.count) rows=\(list.displayed.rows.count) " +
                  "rect=\(list.realizationRect()) bounds=\(list.bounds) scroll=\(list.enclosingScrollView != nil)")
        }
        printHeavy("APP-\(label)", report ?? "")
        printHeavy("DAEMON-\(label)", await daemonSample?.finish() ?? "")
    }

    /// The daemon the simulation started: a `cmux-tui` this process started (at any depth), else the newest `cmux-tui`
    /// whose command line names the Mac's root, else the newest `cmux-tui` (a daemon detaches from its parent).
    private static func daemonPID(under root: String) -> pid_t? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardInput = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        var rows: [ProcessRow] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            let command = String(fields[2])
            if !command.contains("/bin/sample") { rows.append(ProcessRow(pid: pid, parent: parent, command: command)) }
        }
        var mine: Set<pid_t> = [getpid()]
        while true {
            let children = rows.filter { (row: ProcessRow) in mine.contains(row.parent) }.map { (row: ProcessRow) in row.pid }
            let next = mine.union(children)
            if next.count == mine.count { break }
            mine = next
        }
        let daemons = rows.filter { (row: ProcessRow) in row.command.contains("cmux-tui") }
        let newest = { (candidates: [ProcessRow]) -> ProcessRow? in candidates.max { (a: ProcessRow, b: ProcessRow) in a.pid < b.pid } }
        // The simulator's session is `cn-upgrade-<id>` (`ClassicUpgradeSimulator`), on the daemon's command line.
        let pick = newest(daemons.filter { (row: ProcessRow) in row.command.contains("cn-upgrade-") })
            ?? newest(daemons.filter { (row: ProcessRow) in mine.contains(row.pid) })
            ?? newest(daemons.filter { (row: ProcessRow) in row.command.contains(root) })
        return pick?.pid
    }

    /// The `cmux-tui` command lines running now, for the log (which daemon the profile sampled).
    private static func daemonCommands() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardInput = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return text.split(separator: "\n").filter { $0.contains("cmux-tui") }.map { String($0.prefix(200)) }.joined(separator: " | ")
    }

    private struct ProcessRow {
        var pid: pid_t
        var parent: pid_t
        var command: String
    }

    /// User plus system CPU seconds of `pid` (`proc_pid_rusage`).
    private static func cpuSeconds(_ pid: pid_t) -> Double {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// The sample's heaviest call-graph lines (any thread) and its top-of-stack list.
    private static func printHeavy(_ tag: String, _ text: String) {
        let lines = text.components(separatedBy: "\n")
        var printed = 0
        for line in lines where printed < 300 {
            let trimmed = line.drop { $0 == " " || $0 == "+" || $0 == "!" || $0 == ":" || $0 == "|" }
            guard let n = Int(trimmed.prefix { $0.isNumber }), n >= 200 else { continue }
            print("CLASSIC-PROFILE-\(tag) " + String(line.prefix(240)))
            printed += 1
        }
        if let top = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) {
            for line in lines[top..<min(top + 30, lines.count)] { print("CLASSIC-PROFILE-\(tag)-TOP " + line) }
        }
    }
}

/// `/usr/bin/sample` of another process, started now; ``finish()`` returns its report.
@MainActor
private final class ExternalSample {
    private let process = Process()
    private let output: URL

    init(pid: pid_t, seconds: Int) {
        output = FileManager.default.temporaryDirectory.appendingPathComponent("classic-daemon-\(pid)-\(UUID().uuidString.prefix(8)).txt")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(pid), String(seconds), "1", "-mayDie", "-file", output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func finish() async -> String {
        // Bounded: `sample` exits after its window plus symbolication; stopped after 120 s more.
        let clock = ContinuousClock()
        let until = clock.now + .seconds(120)
        while process.isRunning, clock.now < until { try? await Task.sleep(for: .milliseconds(200)) }
        if process.isRunning { process.terminate() }
        defer { try? FileManager.default.removeItem(at: output) }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }
}
