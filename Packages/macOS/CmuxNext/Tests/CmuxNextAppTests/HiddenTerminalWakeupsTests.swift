import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// SWITCH FRAMES warm-set gate (lead 2026-11-03, "batch hidden output"): a warm hidden terminal costs the app process
/// wakeups that the person cannot see. On cmux24 with 24 busy hidden terminals at a warm cap of 25, the app woke 181.8
/// times a second against 76.9 at a cap of 8: about 6.5 wakeups a second for each live hidden terminal, none of them on
/// the main thread (debug.wakeups was equal on both arms). Chrome throttles a background tab's work; a hidden terminal is
/// that case. A live hidden terminal costs (1) no wakeups while idle (Ghostty's cursor blink timer stops while hidden)
/// and (2) one wakeup chain per output batch, not per chunk.
///
/// Measured as differences on one app process, so what does not depend on the hidden terminals being live (the daemon's
/// tree events for busy terminals, the app's own timers) cancels: the same terminals live and hidden, then evicted.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HiddenTerminalWakeupsTests {
    static let terminals = 6
    static let window: Duration = .seconds(6)

    /// Whole-process wakeups (package idle exits plus interrupt wakeups) during `window`.
    static func wakeups(during window: Duration) async throws -> Double {
        let before = try #require(ProcessUsage.sample(getpid()))
        try await Task.sleep(for: window)
        let after = try #require(ProcessUsage.sample(getpid()))
        return Double(after.wakeups &- before.wakeups)
    }

    @Test func aLiveHiddenTerminalWakesTheAppOncePerOutputBatchAndNeverWhileIdle() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let daemon = controller.content?.daemon ?? services.daemon
            let budget = services.cache.warmBudget
            services.cache.setWarmBudget(WarmSetBudget(terminalCapacity: Self.terminals + 4))
            defer { services.cache.setWarmBudget(budget) }

            // Terminals, each shown once (its session is made), then hidden behind another workspace: warm and paused.
            var shells: [(tab: String, surface: SurfaceID)] = []
            for _ in 0..<Self.terminals {
                let id = try #require(await services.windows.createWorkspace(into: controller.state.id))
                try await PinnedPageTests.until({
                    if controller.workspaceContent?.workspace.id != id { services.windows.show(workspaceID: id, in: controller.state) }
                    guard let tab = daemon.store.firstTerminalTab(ofWorkspace: id) else { return false }
                    return services.cache.terminals[tab.id] != nil
                }, report: { "waiting for a terminal session" })
                let tab = try #require(daemon.store.firstTerminalTab(ofWorkspace: id))
                shells.append((tab.id, tab.surface))
            }
            let front = try #require(await services.windows.createWorkspace(into: controller.state.id))
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != front { services.windows.show(workspaceID: front, in: controller.state) }
                return controller.workspaceContent?.workspace.id == front
            }, report: { "waiting for the front workspace" })
            for shell in shells {
                try await connection.send(shell.surface, text: "echo ready$((3*3))\r")
                let ready = try? await connection.request(WaitForTextRequest(surface: shell.surface, pattern: "ready9", timeoutMs: 20_000), timeout: .seconds(25))
                try #require(ready?.matched == true, "the shell of \(shell.tab) never answered")
            }
            try await PinnedPageTests.until({ shells.allSatisfy { services.cache.terminals[$0.tab]?.session.isRenderingSuspended == true } },
                                            report: { "the hidden terminals are not live and paused" })

            // 64 KiB per terminal in about 4 s, as a busy program prints: 400 lines of 160 bytes, 10 ms apart.
            @MainActor func printSixtyFourKiB(_ round: String) async throws {
                for shell in shells {
                    try await connection.send(shell.surface, text: "for i in $(seq 1 400); do printf '%0159d\\n' $i; sleep 0.01; done; echo done-\(round)$((2*3))\r")
                }
            }
            @MainActor func waitPrinted(_ round: String) async throws {
                for shell in shells {
                    let done = try? await connection.request(WaitForTextRequest(surface: shell.surface, pattern: "done-\(round)6", timeoutMs: 30_000), timeout: .seconds(35))
                    try #require(done?.matched == true, "\(shell.tab) never finished printing (\(round))")
                }
            }

            try await Task.sleep(for: .milliseconds(1500))
            let idleLive = try await Self.wakeups(during: Self.window)
            try await printSixtyFourKiB("live")
            let outputLive = try await Self.wakeups(during: Self.window)
            try await waitPrinted("live")

            // The same terminals evicted (no live session in the app): what remains is not the hidden terminals' cost.
            services.cache.setWarmBudget(WarmSetBudget(terminalCapacity: 0))
            try await PinnedPageTests.until({ shells.allSatisfy { !services.cache.hasContent(for: $0.tab) } },
                                            report: { "the warm set kept a hidden terminal" })
            try await Task.sleep(for: .milliseconds(1500))
            let idleEvicted = try await Self.wakeups(during: Self.window)
            try await printSixtyFourKiB("gone")
            let outputEvicted = try await Self.wakeups(during: Self.window)
            try await waitPrinted("gone")

            let seconds = Double(Self.window.components.seconds)
            let idlePerTerminal = (idleLive - idleEvicted) / Double(Self.terminals) / seconds
            let outputPerTerminal = ((outputLive - idleLive) - (outputEvicted - idleEvicted)) / Double(Self.terminals)
            let numbers = "per live hidden terminal: idle \(idlePerTerminal) wakeups/s, \(outputPerTerminal) wakeups per 64 KiB"
                + " (raw over \(seconds) s: idle live \(idleLive), output live \(outputLive), idle evicted \(idleEvicted), output evicted \(outputEvicted))"
            print("hidden-terminal-wakeups: " + numbers)
            // Idle: no timer runs for a terminal the person cannot see (Ghostty's cursor blink: 600 ms, about 1.7/s).
            #expect(idlePerTerminal <= 0.2, "an idle live hidden terminal wakes the app: \(numbers)")
            // Output: the daemon sends a hidden view one batch per wall-clock second (about 5 for this output); each batch
            // may wake the app once. Bound: one wakeup per second of output plus one.
            #expect(outputPerTerminal <= 6, "a live hidden terminal wakes the app more than once per output batch: \(numbers)")
        }
    }
}
