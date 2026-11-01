import AppKit
import CmuxNextActions
import CmuxNextSettings
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// pa-d (smoke gate owner, 2026-11-01): a judged round saw a Ctrl-` right after Cmd-N held by the key router (an empty
/// `debug.key` trace) and could not tell which hold kept it. `debug.focus` reported the New Tab hold
/// (`new_tab_key_holds`, `new_tab_key_log`) but nothing of the creation hold: `CreationInputCoordinator.isHolding` and
/// `lastHoldEnd` were read only by tests. Each window now reports both: `creation_hold` (true while the window's keys wait
/// for a creation) and `creation_hold_end` (how its last creation hold ended).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct DebugFocusCreationHoldTests {
    @Test func debugFocusReportsTheCreationHoldWhileItHoldsAndHowItEnded() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let pid = try #require(services.daemon.identity?.pid)
            let window = try #require(services.windows.active?.window)
            let coordinator = services.keyRouter.creationInputCoordinator
            // The daemon answers nothing, so the Ctrl-`'s creation hold is open while the report is read.
            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            let work = services.registry.capturingWork {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user))
            }
            #expect(coordinator.isHolding(in: window), "the Ctrl-` opened no creation hold")
            let holding = Self.focusWindow(DebugFocus.report(services: services), id: try #require(services.windows.active?.state.id))
            #expect(holding?["creation_hold"] == .bool(true), "debug.focus does not report the open creation hold: \(String(describing: holding))")
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(10),
                                                      report: { "the creation hold never ended" })
            let ended = Self.focusWindow(DebugFocus.report(services: services), id: try #require(services.windows.active?.state.id))
            #expect(ended?["creation_hold"] == .bool(false))
            let end = try #require(coordinator.lastHoldEnd(in: window))
            #expect(ended?["creation_hold_end"] == .string(String(describing: end)),
                    "debug.focus does not report how the creation hold ended: \(String(describing: ended))")
        }
    }

    /// The `windows` entry of `report` for window `id`.
    private static func focusWindow(_ report: JSONValue, id: String) -> [String: JSONValue]? {
        guard case .object(let root) = report, case .array(let windows)? = root["windows"] else { return nil }
        for case .object(let window) in windows where window["id"] == .string(id) { return window }
        return nil
    }
}
