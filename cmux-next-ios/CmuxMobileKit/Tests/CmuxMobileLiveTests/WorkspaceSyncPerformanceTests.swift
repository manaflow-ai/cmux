import CmuxMobileModel
import CmuxMobileTransport
import Darwin
import Foundation
import Testing
@testable import CmuxMobileLive

/// Run this identical file at base and head with the same toolchain and build configuration.
/// At head add `-Xswiftc -DWORKSPACE_DELTA_PUBLICATION` to exercise onRows;
/// base has no such API. Everything else, including the daemon, is identical.
/// Counts real requests and measures actual main-thread CPU, including the
/// production WorkspaceSync and its AppStore publication. No networking,
/// SwiftUI layout, Feed hydration or snapshot disk writes are measured.
@MainActor
@Suite(.serialized) struct WorkspaceSyncPerformanceTests {
    @Test(.timeLimit(.minutes(1)))
    func streamingWorkspaceEvents() async throws {
        let agents = 32
        let ticks = 20
        let interval = Duration.milliseconds(100)
        let daemon = WorkspaceBenchmarkDaemon(agentCount: agents)
        let sync = WorkspaceSync(deviceID: "benchmark", deviceName: "iPhone")
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let setup = WorkspaceBenchmarkSignal()
        let converged = WorkspaceBenchmarkSignal()
        var snapshots = 0
        var rowPublications = 0
        let inspect: @MainActor () -> Void = {
            let expected = "Update \(ticks - 1)"
            if store.workspaces.count == agents,
               store.workspaces.allSatisfy({ $0.tabs.first?.title == expected && $0.tabs.first?.agentStatus == .waiting }) {
                converged.signal()
            }
        }
        sync.onTree = { tree in
            store.replaceWorkspaces(macID: "benchmark", with: tree.workspaces)
            snapshots += 1
            // bind publishes once, then its initial arrangement refresh publishes.
            if snapshots >= 2 { setup.signal() }
            inspect()
        }
        #if WORKSPACE_DELTA_PUBLICATION
        sync.onRows = { tree, ids, _ in
            store.updateWorkspaces(macID: "benchmark", rows: tree.workspaces.filter { ids.contains($0.id) })
            rowPublications += 1
            inspect()
        }
        #endif
        await sync.bind(daemon, macID: "benchmark")
        try await setup.wait()
        let initialFetches = await daemon.fullFetches
        let initialPublications = snapshots
        let start = ContinuousClock.now
        let cpuStart = try Self.threadCPU()
        do {
            for tick in 0..<ticks {
                // Pacing is the workload, never the drain/synchronization oracle.
                try await Task.sleep(for: interval)
                try await daemon.emit(tick: tick)
            }
            try await converged.wait()
            let cpuMilliseconds = try Self.threadCPU() - cpuStart
            let elapsed = Self.seconds(start.duration(to: .now))
            let fetches = await daemon.fullFetches - initialFetches
            let emitted = await daemon.emittedEvents
            let line = "workspace-sync perf agents=\(agents) batches_per_second=10 events_per_batch=\(agents * 2) "
                + "elapsed_seconds=\(elapsed) events=\(emitted) main_cpu_ms=\(cpuMilliseconds) "
                + "main_ms_per_second=\(cpuMilliseconds / elapsed) full_fetches=\(fetches) "
                + "full_fetches_per_minute=\(Double(fetches) * 60 / elapsed) "
                + "snapshot_publications=\(snapshots - initialPublications) row_publications=\(rowPublications)"
            print(line)
            Attachment.record(line, named: "workspace-sync-perf.txt")
            #expect(emitted == ticks * agents * 2)
            #expect(store.workspaces.count == agents)
            #if WORKSPACE_DELTA_PUBLICATION
            #expect(fetches == 0)
            #expect(rowPublications > 0)
            #endif
        } catch {
            await sync.daemon?.close()
            await sync.bind(nil, macID: "benchmark")
            throw error
        }
        await sync.daemon?.close()
        await sync.bind(nil, macID: "benchmark")
    }

    private static func threadCPU() throws -> Double {
        guard Thread.isMainThread else { throw WorkspaceBenchmarkError.notMainThread }
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { throw WorkspaceBenchmarkError.clock }
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private enum WorkspaceBenchmarkError: Error {
    case timeout, notMainThread, clock, malformedRequest
}

/// A publication-driven barrier, with a failure deadline and cancellation of
/// its one deadline task. No yield/poll loop makes a missing callback pass.
@MainActor
private final class WorkspaceBenchmarkSignal {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?

    func signal() {
        signaled = true
        deadline?.cancel()
        deadline = nil
        continuation?.resume()
        continuation = nil
    }

    func wait() async throws {
        if signaled { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.continuation?.resume(throwing: WorkspaceBenchmarkError.timeout)
                self?.continuation = nil
                self?.deadline = nil
            }
        }
    }
}

/// Answers the real DaemonClient's requests. JSON construction and event
/// generation are actor-isolated off main, as on the remote Mac. A batch is
/// emitted atomically, so every full fetch sees all events emitted so far.
private actor WorkspaceBenchmarkDaemon: LinkChannel {
    nonisolated let id: UInt32 = 1
    private let agentCount: Int
    private var tick = -1
    private var inbox: [Data] = []
    private var receiver: CheckedContinuation<Data?, Never>?
    private var closed = false
    private(set) var fullFetches = 0
    private(set) var emittedEvents = 0

    init(agentCount: Int) { self.agentCount = agentCount }

    func send(_ data: Data) throws {
        for line in data.split(separator: 0x0A) {
            guard let request = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = request["id"] as? String else { throw WorkspaceBenchmarkError.malformedRequest }
            var reply: [String: Any] = ["id": id, "ok": true, "data": [:]]
            switch request["cmd"] as? String {
            case "list-workspaces":
                fullFetches += 1
                reply["data"] = ["workspace_revision": 1, "workspaces": rows()]
            case "list-agents":
                reply["data"] = ["agents": (1...agentCount).map { ["surface": $0, "state": "working", "agent": "codex"] }]
            default:
                break
            }
            try push(reply)
        }
    }

    func emit(tick: Int) throws {
        self.tick = tick
        for surface in 1...agentCount {
            try push(["event": "title-changed", "surface": surface, "title": "Update \(tick)"])
            try push(["event": "agent-changed", "surface": surface,
                      "state": tick.isMultiple(of: 2) ? "working" : "blocked", "agent": "codex",
                      "updated_at_ms": 1_700_000_000_000 + tick * 100])
            emittedEvents += 2
        }
    }

    func receive() async -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }

    func close(code: String, reason: String) {
        closed = true
        inbox = []
        receiver?.resume(returning: nil)
        receiver = nil
    }

    private func push(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(0x0A)
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: bytes)
        } else {
            inbox.append(bytes)
        }
    }

    private func rows() -> [[String: Any]] {
        (1...agentCount).map { surface in
            ["id": surface, "key": "workspace-\(surface)", "name": "Agent \(surface)",
             "screens": [["id": surface, "active": true, "active_pane": surface,
                          "panes": [["id": surface, "active_tab": 0,
                                     "tabs": [["surface": surface, "kind": "pty", "title": tick < 0 ? "Initial" : "Update \(tick)"]]]]]]]
        }
    }
}
