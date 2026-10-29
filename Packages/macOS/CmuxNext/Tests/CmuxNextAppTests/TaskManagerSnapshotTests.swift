import CmuxNextResources
import CmuxNextWakeups
import Foundation
import Testing

/// The Task Manager's rows and Kill Process's rule, from synthetic samples and a synthetic
/// process table: what the page lists and what it lets a person end.
@MainActor @Suite
struct TaskManagerSnapshotTests {
    static let app = ProcessKey(pid: 100), daemon = ProcessKey(pid: 200), gpu = ProcessKey(pid: 300)
    static let shell = ProcessKey(pid: 400), renderer = ProcessKey(pid: 500), remote = ProcessKey(host: "m-1", pid: 400)

    static func sample(_ key: ProcessKey, cpu seconds: Double, memory: UInt64, at second: UInt64) -> ProcessSample {
        ProcessSample(key: key, name: "p\(key.pid)", cpuNanos: UInt64(seconds * 1e9), memoryBytes: memory, sampledAtNanos: second * 1_000_000_000)
    }

    static func set(at second: UInt64, cpu: Double) -> TaskManagerSampleSet {
        let keys = [app, daemon, gpu, shell, renderer, remote]
        let samples = Dictionary(uniqueKeysWithValues: keys.map { ($0, sample($0, cpu: cpu * Double($0.pid) / 100, memory: UInt64($0.pid) * 1024, at: second)) })
        let resources = ResourceSampleSet(
            tabs: [
                TabResourceSources(tabID: "tab_a", title: "zsh", kind: .terminal, processes: [shell]),
                TabResourceSources(tabID: "tab_b", title: "Mail", kind: .chromium, processes: [renderer]),
                TabResourceSources(tabID: "tab_c", title: "Inbox", kind: .chromium, processes: [renderer]),
                TabResourceSources(tabID: "tab_d", title: "vm shell", kind: .terminal, processes: [remote]),
            ],
            shared: [SharedProcess(key: app, role: .app), SharedProcess(key: gpu, role: .gpu)],
            samples: samples
        )
        return TaskManagerSampleSet(resources: resources, daemons: [daemon])
    }

    @Test func oneRowPerProcessWithTheAppDaemonAndSharedFirst() throws {
        let snapshot = TaskManagerSnapshot(current: Self.set(at: 2, cpu: 2), previous: Self.set(at: 1, cpu: 1))
        #expect(snapshot.rows.map(\.id) == [Self.app, Self.daemon, Self.gpu, Self.shell, Self.renderer, Self.remote])
        #expect(snapshot.rows.map(\.kind) == [.app, .daemon, .gpu, .terminal, .renderer, .terminal])
        let renderer = try #require(snapshot.row(Self.renderer))
        #expect(renderer.tabIDs == ["tab_b", "tab_c"], "a renderer two tabs share is one row naming both")
        #expect(renderer.task.contains("Mail") && renderer.task.contains("Inbox"))
        // CPU over the interval: (2 - 1) * pid / 100 seconds over 1 second.
        #expect(abs((renderer.cpu ?? 0) - 5) < 0.0001)
        #expect(renderer.memoryBytes == 500 * 1024)
        #expect(snapshot.total.memoryBytes == (100 + 200 + 300 + 400 + 500 + 400) * 1024)
    }

    @Test func cpuWaitsForTheSecondSample() {
        let snapshot = TaskManagerSnapshot(current: Self.set(at: 1, cpu: 1), previous: nil)
        #expect(snapshot.rows.allSatisfy { $0.cpu == nil })
        #expect(snapshot.total.cpu == nil)
    }

    @Test(arguments: [
        ("4242", ProcessKey(pid: 4242)), ("local:7", ProcessKey(pid: 7)), ("m-cloud:9", ProcessKey(host: "m-cloud", pid: 9)),
    ])
    func processTextParses(_ text: String, _ key: ProcessKey) {
        #expect(ProcessKey(parsing: text) == key)
    }

    @Test(arguments: ["", "abc", "0", "-3", ":4", "a:b:4"])
    func badProcessTextDoesNotParse(_ text: String) {
        #expect(ProcessKey(parsing: text) == nil)
    }

    /// pid -> (parent, executable).
    struct Table: ProcessLineage {
        var rows: [Int32: (Int32, String)]
        func parent(of pid: Int32) -> Int32? { rows[pid]?.0 }
        func executablePath(of pid: Int32) -> String? { rows[pid]?.1 }
    }

    static let table = Table(rows: [
        1: (0, "/sbin/launchd"),
        100: (1, "/Applications/cmux.app/Contents/MacOS/cmux"),
        200: (1, "/Applications/cmux.app/Contents/Resources/bin/cmux-tui"),
        210: (1, "/Applications/cmux.app/Contents/Resources/bin/cmux-tui"), // a terminal host launchd adopted
        211: (210, "/bin/zsh"),
        212: (211, "/usr/bin/vim"),
        220: (200, "/bin/zsh"),
        300: (100, "/Applications/cmux.app/Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)"),
        400: (1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc"),
        500: (1, "/Applications/Safari.app/Contents/MacOS/Safari"),
    ])

    static let policy = TaskManagerKillPolicy(appPID: 100, daemonPIDs: [200], bundlePath: "/Applications/cmux.app", listedPIDs: [400])

    @Test(arguments: [Int32(212), 211, 210, 220, 300, 400])
    func cmuxProcessesMayBeEnded(_ pid: Int32) {
        #expect(Self.policy.refusal(for: ProcessKey(pid: pid), lineage: Self.table) == nil)
    }

    @Test func theAppDaemonsOtherAppsAndRemoteProcessesAreRefused() {
        let refusal = { (key: ProcessKey) in Self.policy.refusal(for: key, lineage: Self.table) }
        #expect(refusal(ProcessKey(pid: 100)) == .appProcess)
        #expect(refusal(ProcessKey(pid: 200)) == .daemonProcess)
        #expect(refusal(ProcessKey(pid: 1)) == .notCmuxProcess)
        #expect(refusal(ProcessKey(pid: 500)) == .notCmuxProcess)
        #expect(refusal(ProcessKey(pid: 999)) == .notRunning)
        #expect(refusal(ProcessKey(host: "m-1", pid: 211)) == .remoteHost)
        #expect(TaskManagerKillRefusal.daemonProcess.message.isEmpty == false)
    }

    final class Source: TaskManagerSampleSource {
        var second: UInt64 = 0
        func sample() async -> TaskManagerSampleSet {
            second += 1
            return TaskManagerSnapshotTests.set(at: second, cpu: Double(second))
        }
    }

    @Test func theModelRefreshesKeepsLiveSelectionAndRoutesKill() async {
        let source = Source()
        var killed: [ProcessKey] = []
        let model = TaskManagerModel(source: source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     kill: { killed.append($0) })
        await model.refresh()
        #expect(model.snapshot.rows.count == 6)
        #expect(model.snapshot.rows.allSatisfy { $0.cpu == nil })
        model.selection = [Self.shell, ProcessKey(pid: 31337)]
        await model.refresh()
        #expect(model.selection == [Self.shell], "a process that is gone leaves the selection")
        #expect(model.snapshot.row(Self.shell)?.cpu != nil)
        #expect(model.selectedRow?.id == Self.shell)
        model.kill(Self.shell)
        #expect(killed == [Self.shell])
    }

    /// A source whose sample waits until the test releases it.
    final class GatedSource: TaskManagerSampleSource {
        var calls = 0
        private var gate: CheckedContinuation<Void, Never>?
        func sample() async -> TaskManagerSampleSet {
            calls += 1
            await withCheckedContinuation { gate = $0 }
            return TaskManagerSnapshotTests.set(at: UInt64(calls), cpu: 1)
        }
        func release() {
            gate?.resume()
            gate = nil
        }
    }

    /// Closing the page while a sample runs: that sample's result is dropped, not written after stop().
    @Test func stopDuringASampleDropsItsResult() async throws {
        let source = GatedSource()
        let model = TaskManagerModel(source: source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     kill: { _ in })
        model.start()
        var tries = 0
        while source.calls < 1, tries < 500 { tries += 1; try await Task.sleep(for: .milliseconds(2)) }
        #expect(source.calls == 1, "start() took a sample at once")
        model.stop()
        source.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.sampleCount == 0, "the sample in flight at stop() was applied")
        #expect(model.snapshot.rows.isEmpty)
        #expect(!model.isRunning)
    }
}
