import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// A closed terminal tab's program keeps running until the daemon's reap grace ends, and Reopen
/// Closed Tab brings back the same running process with its output going on. A close that does
/// not ask (a program that started an instant before the press, PL-burst's local close decision)
/// is safe only while this holds: the close loses nothing the undo cannot bring back.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClosedTerminalKeepsRunningTests {
    /// A counter loop in a terminal tab; the tab closes; for two seconds its process is alive (no
    /// SIGHUP: `sh` ends on one); Reopen Closed Tab shows the same terminal, the same pid, and the
    /// counter still counting on its screen.
    @Test func aClosedTerminalsProgramRunsOnAndReopenBringsTheSameProcessBack() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            // `new-tab` runs the shell (SHELL=/bin/sh here) with these arguments; it takes no argv.
            // Each tick also goes to a file, so the test sees the program run while its tab is closed.
            let ticks = FileManager.default.temporaryDirectory.appendingPathComponent("ctkr-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: ticks) }
            let loop = "i=0; while :; do i=$((i+1)); echo tick-$i; echo $i > '\(ticks.path)'; sleep 0.1; done"
            var spawn = SpawnOptions()
            spawn.shellArgs = ["-c", loop]
            let created = try await connection.newTab(in: model.handle, options: spawn)
            try await PinnedPageTests.until({ store.tab(surface: created.surface)?.terminalID != nil })
            let terminal = try #require(store.tab(surface: created.surface)?.terminalID)
            let tabID = try #require(store.tab(surface: created.surface)?.id)
            let pid = try #require(try await connection.request(TerminalProcessInfoRequest(surface: created.surface)).pid)
            let before = try await Self.lastTick(connection, created.surface)

            let close = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabID), origin: .cli)
            #expect(services.registry.perform("closeTab", invocation: close))
            try await PinnedPageTests.until({ store.tab(surface: created.surface) == nil }, report: { "the tab did not close" })
            @MainActor func fileTick() -> Int {
                (try? String(contentsOf: ticks, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            }
            let atClose = fileTick()
            for _ in 0..<20 {
                #expect(kill(pid_t(pid), 0) == 0, "the closed terminal's process \(pid) ended before the reap grace")
                try await Task.sleep(for: .milliseconds(100))
            }
            // The counter went on while the tab was closed (how far depends on the host's load).
            try await PinnedPageTests.until({ fileTick() > atClose + 1 }, report: { "the counter stopped while closed: \(atClose) then \(fileTick())" })

            #expect(services.registry.perform("reopenClosedBrowserPanel", invocation: ActionInvocation(origin: .user)))
            @MainActor func reopened() -> TabModel? {
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.terminalID == terminal }
            }
            try await PinnedPageTests.until({ reopened() != nil }, report: { "Reopen Closed Tab did not bring the terminal back" })
            let surface = try #require(reopened()?.surface)
            let reopenedPID = try await connection.request(TerminalProcessInfoRequest(surface: surface)).pid
            #expect(reopenedPID == pid, "the reopened tab runs pid \(String(describing: reopenedPID)), not the closed one's \(pid)")
            let first = try await Self.lastTick(connection, surface)
            #expect(first > before, "the reopened screen shows no tick past \(before): \(first)")
            try await Task.sleep(for: .milliseconds(500))
            let next = try await Self.lastTick(connection, surface)
            #expect(next > first, "the counter does not go on in the reopened tab: \(first) then \(next)")
        }
    }

    /// The highest `tick-N` on the terminal's screen, once one shows.
    private static func lastTick(_ connection: DaemonConnection, _ surface: SurfaceID) async throws -> Int {
        var tick = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while tick == 0, ContinuousClock.now < deadline {
            let text = try await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)).text
            tick = text.split(whereSeparator: \.isNewline).compactMap { line in
                line.hasPrefix("tick-") ? Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) : nil
            }.max() ?? 0
            if tick == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(tick > 0, "no tick on the terminal's screen")
        return tick
    }
}
