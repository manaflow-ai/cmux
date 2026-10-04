import CmuxNextServer
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A scripted bundled CLI: answers by argument list, records every call.
nonisolated final class FakeServerCLI: Sendable {
    private let state = Mutex<(answers: [[String]: LocalServerSource.CLIResult], calls: [[String]])>(([:], []))

    func answer(_ arguments: [String], status: Int32 = 0, _ stdout: String = "") {
        state.withLock { $0.answers[arguments] = LocalServerSource.CLIResult(status: status, stdout: Data(stdout.utf8)) }
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    func run(_ arguments: [String]) -> LocalServerSource.CLIResult? {
        state.withLock {
            $0.calls.append(arguments)
            return $0.answers[arguments]
        }
    }
}

final class FakeServerWatcher: ServerFileWatching {
    let file: URL
    let onChange: @Sendable () -> Void
    var started = false
    var stopped = false

    init(file: URL, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.onChange = onChange
    }

    func start() { started = true }
    func stop() { stopped = true }
}

/// Waits (bounded) for work that runs off the main actor.
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<3000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
@Suite struct LocalServerSourceTests {
    static let home = URL(fileURLWithPath: "/Users/ada")
    static let status = #"{"enabled": true, "mode": "user", "store": {"version": "0.9.1", "channel": "stable", "pinned": null}, "roles": []}"#
    static let roles = #"{"roles": [{"name": "session", "state": "ready"}]}"#

    final class Harness {
        let cli = FakeServerCLI()
        var watchers: [FakeServerWatcher] = []
        var events: [ServerSourceEvent] = []
        var fixes: [HealthCheckID] = []
        var fixReject: String?
        var source: LocalServerSource!

        var snapshots: [ServerSnapshot] { events.compactMap { if case let .snapshot(s) = $0 { s } else { nil } } }
        var unavailable: [String] { events.compactMap { if case let .connection(.unavailable(r)) = $0 { r } else { nil } } }
        func settled(_ key: String) -> String?? {
            for case let .settled(k, reject) in events where k == key { return .some(reject) }
            return nil
        }
        func statusReads() -> Int { cli.calls.filter { $0 == LocalServerSource.statusArguments }.count }
    }

    func harness(binary: URL? = URL(fileURLWithPath: "/App/Contents/Resources/bin/cmux"),
                 fix: LocalServerSource.Fix? = nil) -> Harness {
        let harness = Harness()
        harness.cli.answer(LocalServerSource.statusArguments, Self.status)
        harness.cli.answer(LocalServerSource.rolesArguments, Self.roles)
        let cli = harness.cli
        harness.source = LocalServerSource(
            binary: binary, hostName: "Mac mini", watchedFiles: LocalServerSource.watchedFiles(home: Self.home),
            runCLI: { _, arguments in cli.run(arguments) },
            // Weak captures: a read can still finish after a test ends.
            fix: { [weak harness] check in
                harness?.fixes.append(check)
                if let fix { return await fix(check) }
                return harness?.fixReject
            },
            makeWatcher: { [weak harness] file, onChange in
                let watcher = FakeServerWatcher(file: file, onChange: onChange)
                harness?.watchers.append(watcher)
                return watcher
            })
        return harness
    }

    func started(_ harness: Harness) -> Harness {
        harness.source.start { [weak harness] in harness?.events.append($0) }
        return harness
    }

    @Test func startReadsStatusAndRolesIntoASnapshot() async {
        let h = started(harness())
        #expect(await eventually { !h.snapshots.isEmpty })
        #expect(h.cli.calls.contains(["server", "status", "--json"]))
        #expect(h.cli.calls.contains(["host", "roles", "--json"]))
        #expect(h.snapshots.first?.hostName == "Mac mini")
        #expect(h.snapshots.first?.enabled == true)
        #expect(h.snapshots.first?.roles == [ServerRoleStatus(.session, .on)])
    }

    @Test func aMissingCLIIsUnavailableWithoutRunningAnything() async {
        let h = started(harness(binary: nil))
        #expect(await eventually { !h.unavailable.isEmpty })
        #expect(h.cli.calls.isEmpty)
        #expect(h.snapshots.isEmpty)
    }

    @Test func aCLIWithoutServerVerbsOrAFailingStatusIsUnavailable() async {
        let usage = harness()
        usage.cli.answer(LocalServerSource.statusArguments, status: 2, "")
        _ = started(usage)
        #expect(await eventually { !usage.unavailable.isEmpty })
        #expect(usage.snapshots.isEmpty)

        let failing = harness()
        failing.cli.answer(LocalServerSource.statusArguments, status: 1, "")
        _ = started(failing)
        #expect(await eventually { !failing.unavailable.isEmpty })
        #expect(failing.unavailable != usage.unavailable, "a missing server and a failing one read differently")

        // An older `cmux` routes `server status` to the terminal daemon.
        let daemon = harness()
        daemon.cli.answer(LocalServerSource.statusArguments, #"{"status": "running", "session": "cmux-app"}"#)
        _ = started(daemon)
        #expect(await eventually { !daemon.unavailable.isEmpty })
        #expect(daemon.unavailable == usage.unavailable)
    }

    @Test func noRolesFileYetStillServesTheStatus() async {
        let h = harness()
        h.cli.answer(LocalServerSource.rolesArguments, status: 3, "")
        _ = started(h)
        #expect(await eventually { !h.snapshots.isEmpty })
        #expect(h.snapshots.first?.roles.isEmpty == true)
    }

    @Test func itWatchesTheRolesStatusAndTheConfigAndReadsAgainOnAChange() async {
        let h = started(harness())
        #expect(await eventually { h.snapshots.count == 1 })
        #expect(h.watchers.map(\.file.path) == [
            "/Users/ada/Library/Application Support/cmux/server/roles/status.json",
            "/Users/ada/.config/cmux/server.json",
        ])
        #expect(h.watchers.allSatisfy { $0.started })
        h.cli.answer(LocalServerSource.rolesArguments, #"{"roles": [{"name": "session", "state": "crash-loop"}]}"#)
        h.watchers[0].onChange()
        #expect(await eventually { h.snapshots.count == 2 })
        #expect(h.snapshots.last?.roles == [ServerRoleStatus(.session, .failed)])
        let reads = h.statusReads()
        h.watchers[1].onChange()
        #expect(await eventually { h.statusReads() == reads + 1 })
        #expect(h.snapshots.count == 2, "an unchanged status is not sent again")
    }

    @Test func stopEndsTheWatchesAndTheReads() async {
        let h = started(harness())
        #expect(await eventually { h.snapshots.count == 1 })
        h.source.stop()
        #expect(h.watchers.allSatisfy { $0.stopped })
        let reads = h.statusReads()
        h.watchers[0].onChange()
        h.source.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.statusReads() == reads)
    }

    @Test func everyIntentSettlesAndReadsTheStatusAgain() async {
        let h = started(harness())
        #expect(await eventually { h.snapshots.count == 1 })
        let reads = h.statusReads()
        h.source.send(ServerIntent(kind: .openHealth, key: "open"))
        h.source.send(ServerIntent(kind: .showPairingCode, key: "pair"))
        #expect(h.settled("open") == .some(nil))
        #expect(h.settled("pair") != nil && h.settled("pair") != .some(nil), "not served yet: a refusal")
        #expect(await eventually { h.statusReads() > reads })
    }
}
