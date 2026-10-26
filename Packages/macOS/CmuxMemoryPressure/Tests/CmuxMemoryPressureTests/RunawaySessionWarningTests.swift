import Testing

@testable import CmuxMemoryPressure

/// The user-facing half of https://github.com/manaflow-ai/cmux/issues/22273:
/// cmux must say which terminal is running away, with its command, process
/// count and memory, before macOS takes the app down.
@Suite("Runaway session warning")
struct RunawaySessionWarningTests {
    private static let gb: Int64 = 1024 * 1024 * 1024
    private static let tty: Int64 = 0x1600_0003

    private func process(
        _ pid: Int,
        parent: Int,
        name: String = "node",
        group: Int,
        bytes: Int64,
        tty: Int64? = Self.tty
    ) -> RunawaySessionProcess {
        RunawaySessionProcess(
            pid: pid, parentPID: parent, name: name,
            processGroupID: group, ttyDevice: tty, memoryBytes: bytes
        )
    }

    /// login(100) -> zsh(200) -> `next dev`(300) + workers in group 300.
    private func forkStorm(workers: Int, workerBytes: Int64, includeLeader: Bool = true) -> RunawaySessionCensus {
        var processes = [
            process(100, parent: 50, name: "login", group: 100, bytes: 4_000_000),
            process(200, parent: 100, name: "zsh", group: 200, bytes: 8_000_000),
        ]
        if includeLeader {
            processes.append(process(300, parent: 200, group: 300, bytes: 200_000_000))
        }
        for index in 0..<workers {
            processes.append(process(1_000 + index, parent: includeLeader ? 300 : 1, group: 300,
                                     bytes: workerBytes + Int64(index)))
        }
        processes.append(process(9_000, parent: 1, name: "other", group: 9_000, bytes: 40 * Self.gb, tty: nil))
        return RunawaySessionCensus(processes: processes)
    }

    private let policy = RunawaySessionWarningPolicy(memoryThresholdBytes: 8 * gb, processCountThreshold: 1_000)

    @Test("usage counts only the terminal's processes and names the job leader")
    func usageNamesTheJob() {
        let usage = forkStorm(workers: 1_200, workerBytes: 1_000_000)
            .usage(ttyDevice: Self.tty, candidateGroups: [300])

        #expect(usage?.processCount == 1_203)
        #expect(usage?.dominantProcessID == 300)
        #expect(usage.map(policy.isRunaway) == true)
    }

    @Test("without its leader, the largest worker names the job")
    func usageFallsBackToTheLargestWorker() {
        let usage = forkStorm(workers: 10, workerBytes: Self.gb, includeLeader: false)
            .usage(ttyDevice: Self.tty, candidateGroups: [300])

        #expect(usage?.dominantProcessID == 1_009)
        #expect(usage?.processCount == 12)
    }

    @Test("a terminal warns on memory or process count, once per crossing")
    func warnsOncePerCrossing() {
        var tracker = RunawaySessionWarningTracker<String>()
        let quiet = RunawaySessionUsage(ttyDevice: Self.tty, memoryBytes: Self.gb, processCount: 20, dominantProcessID: 300)
        let forkBomb = RunawaySessionUsage(ttyDevice: Self.tty, memoryBytes: Self.gb, processCount: 3_574, dominantProcessID: 300)
        let leak = RunawaySessionUsage(ttyDevice: Self.tty, memoryBytes: 9 * Self.gb, processCount: 4, dominantProcessID: 300)
        let banded = RunawaySessionUsage(ttyDevice: Self.tty, memoryBytes: 7 * Self.gb, processCount: 4, dominantProcessID: 300)

        #expect(tracker.ingest(["a": quiet, "b": quiet], policy: policy).isEmpty)
        #expect(tracker.ingest(["a": forkBomb, "b": leak], policy: policy) == ["a", "b"])
        #expect(tracker.ingest(["a": forkBomb, "b": leak], policy: policy).isEmpty)
        #expect(tracker.ingest(["a": forkBomb, "b": banded], policy: policy).isEmpty)
        #expect(tracker.isPresentable("b"), "the hysteresis band keeps the warning")
        #expect(tracker.ingest(["a": quiet, "b": quiet], policy: policy).isEmpty)
        #expect(!tracker.isPresentable("a"))
        #expect(tracker.ingest(["a": forkBomb], policy: policy) == ["a"])
    }

    @Test("a dismissed warning stays quiet until the terminal clears")
    func dismissalHoldsUntilClear() {
        var tracker = RunawaySessionWarningTracker<String>()
        let leak = RunawaySessionUsage(ttyDevice: Self.tty, memoryBytes: 9 * Self.gb, processCount: 4, dominantProcessID: 300)
        let quiet = RunawaySessionUsage(ttyDevice: Self.tty, memoryBytes: Self.gb, processCount: 4, dominantProcessID: 300)

        _ = tracker.ingest(["a": leak], policy: policy)
        tracker.dismiss("a")
        #expect(!tracker.isPresentable("a"))
        #expect(tracker.ingest(["a": leak], policy: policy).isEmpty)
        _ = tracker.ingest(["a": quiet], policy: policy)
        #expect(tracker.ingest(["a": leak], policy: policy) == ["a"])
        #expect(tracker.isPresentable("a"))
        _ = tracker.ingest([:], policy: policy)
        #expect(tracker.warned.isEmpty, "closed terminals are forgotten")
    }

    @Test("argv becomes a short command label")
    func commandLabels() {
        let labeler = RunawaySessionCommandLabeler()

        #expect(labeler.label(arguments: ["node", "/app/node_modules/.bin/next", "dev"], processName: "node") == "next dev")
        #expect(labeler.label(arguments: ["/usr/local/bin/node", "--inspect", "server.js"], processName: "node") == "node")
        #expect(labeler.label(arguments: ["/usr/bin/make", "-j8"], processName: "make") == "make")
        #expect(labeler.label(arguments: ["/usr/bin/python3.12", "-u", "train.py"], processName: "python3.12") == "python3.12")
        #expect(labeler.label(arguments: [], processName: "node") == "node")
        #expect(labeler.label(arguments: ["tool"] + Array(repeating: "argument", count: 20), processName: "tool") == "tool")
    }

    @Test("notification labels never expose arbitrary arguments", arguments: [
        (["curl", "--header", "Authorization: Bearer secret", "https://private.example"], "curl", "curl"),
        (["node", "/app/node_modules/.bin/next", "dev", "--token=secret"], "node", "next dev"),
        (["python3.12", "-c", "print('secret')"], "python3.12", "python3.12"),
        (["node", "--require", "/private/secret.js"], "node", "node"),
        (["node", "/private/secret-project/server.js", "password"], "node", "node"),
        (["tool", "--password=secret"], "tool", "tool"),
    ])
    func commandLabelsHideArguments(arguments: [String], name: String, expected: String) {
        #expect(RunawaySessionCommandLabeler().label(arguments: arguments, processName: name) == expected)
    }
}
