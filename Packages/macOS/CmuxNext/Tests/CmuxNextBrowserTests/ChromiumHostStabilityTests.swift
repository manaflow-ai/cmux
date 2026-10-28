#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
@testable import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// p09-observability-109: each end of the Chromium Host that leaves a crash record (not a clean exit, not while cmux
/// quits) is one `stability.child_exit.chromium_host` sample, valued by how it ended.
@MainActor
@Suite struct ChromiumHostStabilityTests {
    /// A supervisor over hosts with no process behind them, counting into a store of the test's own.
    private static func rig() -> (ChromiumHostSupervisor, StabilityEndingSpawner, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        _ = store.attach(to: runtime)
        let spawner = StabilityEndingSpawner()
        let supervisor = ChromiumHostSupervisor(spawner: spawner, stability: StabilityCounters(metrics: Metrics(runtime: runtime)))
        return (supervisor, spawner, store)
    }

    /// `[ChildExit value: count]` of `stability.child_exit.chromium_host`.
    private static func exits(_ store: MetricsStore) -> [Int: UInt64] {
        let name = HistogramID.stabilityChildExit(.chromiumHost).name
        let histogram = store.delta().histograms.first { $0.name == name }
        return Dictionary(uniqueKeysWithValues: (histogram?.buckets ?? []).map { ($0.index, $0.count) })
    }

    @Test func aTrappedHostCountsOneSignal() async throws {
        let (supervisor, spawner, store) = Self.rig()
        _ = try await supervisor.attachment()
        supervisor.hostSaidHello()
        spawner.end(try #require(supervisor.hostPID), ChromiumHostExit(signal: SIGTRAP, status: nil))
        #expect(supervisor.crashesTotal == 1)
        #expect(Self.exits(store) == [Int(HistogramID.ChildExit.signal.rawValue): 1])
    }

    @Test func aHostThatExitsOnAFatalErrorCountsOnePanic() async throws {
        let (supervisor, spawner, store) = Self.rig()
        _ = try await supervisor.attachment()
        spawner.end(try #require(supervisor.hostPID), ChromiumHostExit(signal: nil, status: 65))
        #expect(Self.exits(store) == [Int(HistogramID.ChildExit.panic.rawValue): 1])
    }

    @Test func aCleanExitAndAnEndWhileQuittingCountNothing() async throws {
        let (supervisor, spawner, store) = Self.rig()
        _ = try await supervisor.attachment()
        supervisor.hostSaidHello()
        spawner.end(try #require(supervisor.hostPID), ChromiumHostExit(signal: nil, status: 0))
        #expect(Self.exits(store).isEmpty, "a clean exit (quit or the idle exit) was counted")
        supervisor.isQuitting = { true }
        _ = try await supervisor.attachment()
        supervisor.hostSaidHello()
        spawner.end(try #require(supervisor.hostPID), ChromiumHostExit(signal: SIGKILL, status: nil))
        #expect(Self.exits(store).isEmpty, "quit's end of the host was counted")
    }

    @Test func eachEndMapsToItsChildExit() {
        #expect(ChromiumHostExit(signal: SIGSEGV, status: nil).childExit == .signal)
        #expect(ChromiumHostExit(signal: nil, status: nil).childExit == .signal, "an end with no status read")
        #expect(ChromiumHostExit(signal: nil, status: 1).childExit == .panic)
        #expect(ChromiumHostExit(signal: nil, status: 0).childExit == .clean)
    }
}

/// Hands out hosts with no process behind them; the test ends each one (``end(_:_:)``) on the main thread, as the lane
/// spawner's exit post does.
private nonisolated final class StabilityEndingSpawner: ChromiumHostSpawning {
    private let state = Mutex<(next: pid_t, watchers: [pid_t: @MainActor @Sendable (ChromiumHostExit, [String]) -> Void])>((next: 41_000, watchers: [:]))

    func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
        let pid = state.withLock { state in
            state.next += 1
            return state.next
        }
        let attachment = ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                                frameworkLocales: [])
        return ChromiumHostSpawn(pid: pid, attachment: attachment)
    }

    func watchExit(of pid: pid_t, log: URL?, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit, [String]) -> Void) {
        state.withLock { $0.watchers[pid] = ended }
    }

    func reap(_ pid: pid_t) {}

    func kill(_ pid: pid_t) {}

    @MainActor func end(_ pid: pid_t, _ exit: ChromiumHostExit) {
        let ended = state.withLock { $0.watchers.removeValue(forKey: pid) }
        ended?(exit, [])
    }
}
#endif
