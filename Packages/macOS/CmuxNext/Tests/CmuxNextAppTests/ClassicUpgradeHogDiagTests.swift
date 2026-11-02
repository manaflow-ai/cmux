import AppKit
@testable import CmuxNextApp
import CmuxNextOnboarding
import Foundation
import Testing

/// DIAG #32408 (experiment, not for merge): the classic upgrade simulation under a CPU hog (one `yes` per core), with
/// the daemon and this test process sampled while it runs, so the log says who waits on what.
@MainActor @Suite(.serialized, .timeLimit(.minutes(15)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeHogDiagTests {
    /// Runs `path` with `arguments` and returns its standard output once it exits (off the main actor).
    nonisolated static func run(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let collected = DiagBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.availableData)
                done.resume(returning: collected.text)
            }
            do { try process.run() } catch { done.resume(returning: "run failed: \(error)") }
        }
    }

    /// The hog: one `yes > /dev/null` per core, at the default priority (as a second fleet step's compile is).
    final class Hog {
        private var processes: [Process] = []
        init(count: Int = ProcessInfo.processInfo.activeProcessorCount) {
            for _ in 0..<count {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
                process.standardOutput = FileHandle.nullDevice
                try? process.run()
                processes.append(process)
            }
            print("DIAG32408 hog started: \(processes.count) yes processes")
        }
        func stop() {
            for process in processes where process.isRunning { process.terminate() }
            print("DIAG32408 hog stopped")
        }
    }

    /// Samples the daemons of this simulation (`cn-upgrade-` sessions) and this test process for `seconds`, and prints
    /// each one's heaviest stacks (`sample`'s "Sort by top of stack" section) and its main thread's call graph head.
    nonisolated static func sampleAll(_ label: String, seconds: Int = 2) async {
        let me = ProcessInfo.processInfo.processIdentifier
        let daemons = await run("/usr/bin/pgrep", ["-f", "cn-upgrade-"]).split(separator: "\n").compactMap { Int32($0) }.filter { $0 != me }
        let load = await run("/usr/sbin/sysctl", ["-n", "vm.loadavg"])
        print("DIAG32408 sample \(label) load=\(load.trimmingCharacters(in: .whitespacesAndNewlines)) daemons=\(daemons) test=\(me)")
        let top = await run("/usr/bin/top", ["-l", "1", "-n", "8", "-o", "cpu", "-stats", "pid,command,cpu,state"])
        print("DIAG32408 top \(label)\n" + top.split(separator: "\n").suffix(10).joined(separator: "\n"))
        for (name, pid) in [("test", me)] + daemons.map({ ("daemon", $0) }) {
            let file = NSTemporaryDirectory() + "diag32408-\(pid)-\(UUID().uuidString.prefix(6)).txt"
            _ = await run("/usr/bin/sample", ["\(pid)", "\(seconds)", "-mayDie", "-file", file])
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let graph = lines.firstIndex { $0.hasPrefix("Call graph:") }
            let heavy = lines.firstIndex { $0.hasPrefix("Total number in stack") || $0.hasPrefix("Sort by top of stack") }
            print("DIAG32408 \(name) \(pid) \(label) CALLGRAPH")
            if let graph { print(lines[graph..<min(lines.count, graph + 70)].map { String($0.prefix(220)) }.joined(separator: "\n")) }
            print("DIAG32408 \(name) \(pid) \(label) HEAVIEST")
            if let heavy { print(lines[heavy..<min(lines.count, heavy + 30)].map { String($0.prefix(220)) }.joined(separator: "\n")) }
            try? FileManager.default.removeItem(atPath: file)
        }
    }

    /// The small profile under the hog, sampled every 4 s while the migration runs.
    @Test func smallUnderAHog() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let hog = Hog()
        defer { hog.stop() }
        // task-owner: this test's sampler; cancelled at its end
        let sampler = Task.detached {
            var round = 0
            while !Task.isCancelled, round < 12 {
                try? await Task.sleep(for: .seconds(4))
                round += 1
                await Self.sampleAll("small-hog-\(round)")
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let launch = await sim.launch()
        print(String(format: "DIAG32408 small-hog migration=%.2fs failure=%@ made=%d", (clock.now - start).simSeconds,
                     String(describing: launch.failure), sim.made().count))
        sampler.cancel()
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }

    private final class HugeRun {
        let mac: ClassicUpgradeSimulator.Mac
        let sim: ClassicUpgradeSimulator
        let before: [String: String]
        var outcome: ClassicMigrationOutcome?
        var finished = false
        var hog: Hog?
        var sampler: Task<Void, Never>?
        init() throws {
            mac = try ClassicUpgradeSimulator.Mac()
            try mac.save(ClassicUpgradeProfile.huge)
            before = try mac.classicDigest()
            sim = try ClassicUpgradeSimulator(mac: mac)
        }
    }

    private static var huge: HugeRun?

    /// The 512-workspace profile under the hog, in phases as `ClassicUpgradeHugeSimulationTests`, sampled every 30 s.
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func hugeUnderAHog(_ phase: Int) async throws {
        switch phase {
        case 0:
            let run = try HugeRun()
            Self.huge = run
            run.hog = Hog()
            // task-owner: the huge diag's sampler; cancelled in phase 5
            run.sampler = Task.detached {
                var round = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    round += 1
                    await Self.sampleAll("huge-hog-\(round)")
                }
            }
            let launch = await run.sim.launch(deadline: .seconds(150))
            run.outcome = launch.outcome
            if case .overBudget? = launch.failure as? ClassicUpgradeSimulator.SimulationFailure {} else { run.finished = true }
            print(String(format: "DIAG32408 huge-hog phase0=%.2fs made=%d", launch.migration.simSeconds, run.sim.made().count))
        case 1...4:
            let run = try #require(Self.huge)
            guard !run.finished, let task = run.sim.services.onboarding.classicMigrationRun else { return }
            if let outcome = await run.sim.wait(for: task, upTo: .seconds(150)) {
                run.outcome = outcome
                run.finished = true
            }
            print("DIAG32408 huge-hog phase\(phase) made=\(run.sim.made().count) finished=\(run.finished)")
        default:
            let run = try #require(Self.huge)
            defer { Self.huge = nil }
            run.sampler?.cancel()
            run.hog?.stop()
            print("DIAG32408 huge-hog finished=\(run.finished) made=\(run.sim.made().count) \(run.sim.perWorkspaceReport())")
            await run.sim.shutdown()
        }
    }
}

/// Collects a pipe's bytes from its readability handler.
nonisolated final class DiagBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
