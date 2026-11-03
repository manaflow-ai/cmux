import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// SWITCH FRAMES warm-set gate (lead 2026-11-03, "batch hidden output"): a warm hidden terminal costs the app process
/// wakeups that the person cannot see. On cmux24 with 24 busy hidden terminals at a warm cap of 25, the app woke 181.8
/// times a second against 76.9 at a cap of 8, none of it on the main thread. Chrome throttles a background tab's work; a
/// hidden terminal is that case. Its output path (the attach reader thread, the session's consumer task, the output
/// lane) runs once per output batch, not once per chunk, and not at all while the terminal is idle.
///
/// Exact counts per hidden terminal, not wakeups (a whole-process wakeup count moved by up to 346 in 6 s between two
/// windows of one app with nothing changed: STATUS 9985 follow-up). The whole-process figure stays the fleet A/B gate.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HiddenTerminalWakeupsTests {
    static let terminals = 4

    /// One hidden terminal's work so far on every thread it wakes: the attach reader's reads, the consumer's passes, the
    /// lane's blocks, and Ghostty's renderer and termio thread wakes by source (ghostty_surface_render_counters, fork #73).
    struct Work: CustomStringConvertible {
        var reads: UInt64, passes: UInt64, blocks: UInt64
        var rendererWakeups: UInt64, drawNow: UInt64, timers: UInt64, ioWakeups: UInt64, ioTimers: UInt64
        static func of(_ entry: TerminalEntry) -> Work? {
            guard let reads = entry.io.driver.machine.liveLink?.link.transportReads, let lane = entry.session.surfaceView.lane,
                  let surface = entry.session.surfaceView.surface else { return nil }
            let c = ghostty_surface_render_counters(surface)
            return Work(reads: reads, passes: entry.session.frameChanges.generation, blocks: lane.blocks,
                        rendererWakeups: c.renderer_wakeups, drawNow: c.renderer_draw_now,
                        timers: c.renderer_cursor_timer_fires &+ c.renderer_animation_timer_fires &+ c.renderer_compression_timer_fires,
                        ioWakeups: c.io_wakeups, ioTimers: c.io_timer_fires)
        }
        static func - (a: Work, b: Work) -> Work {
            Work(reads: a.reads &- b.reads, passes: a.passes &- b.passes, blocks: a.blocks &- b.blocks,
                 rendererWakeups: a.rendererWakeups &- b.rendererWakeups, drawNow: a.drawNow &- b.drawNow, timers: a.timers &- b.timers,
                 ioWakeups: a.ioWakeups &- b.ioWakeups, ioTimers: a.ioTimers &- b.ioTimers)
        }
        /// Wake chains started: each read of a batch starts one; the lane, renderer and termio hand-offs of that batch go on
        /// the same chain, and any wake past one per lane block (or a timer fire) starts another.
        var chains: UInt64 {
            func past(_ wakes: UInt64) -> UInt64 { wakes > blocks ? wakes - blocks : 0 }
            return reads &+ timers &+ ioTimers &+ past(rendererWakeups) &+ past(ioWakeups) &+ past(drawNow)
        }
        var description: String {
            "\(reads) reads, \(passes) consumer passes, \(blocks) lane blocks, renderer \(rendererWakeups) wakeups + \(drawNow) draw-now"
                + " + \(timers) timer fires, termio \(ioWakeups) wakeups + \(ioTimers) timer fires"
        }
    }

    @Test func aHiddenTerminalsOutputPathRunsOncePerBatchAndNeverWhileIdle() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let daemon = controller.content?.daemon ?? services.daemon
            let budget = services.cache.warmBudget
            services.cache.setWarmBudget(WarmSetBudget(terminalCapacity: Self.terminals + 4))
            defer { services.cache.setWarmBudget(budget) }

            // Terminals, each shown once (its session is made), then hidden behind another workspace: live and hidden.
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
            try await PinnedPageTests.until({ shells.allSatisfy { services.cache.terminals[$0.tab]?.session.diagnostics.drawing == false } },
                                            report: { "the hidden terminals are not live and paused" })
            @MainActor func work() throws -> [Work] {
                try shells.map { shell in
                    let entry = try #require(services.cache.terminals[shell.tab], "\(shell.tab) is not live")
                    return try #require(Work.of(entry), "\(shell.tab) has no live attach link or lane")
                }
            }
            try await Task.sleep(for: .seconds(3)) // the echo's batch and its digest land

            // Idle: a hidden terminal with no output does no output-path work.
            let idleStart = try work()
            try await Task.sleep(for: .seconds(6))
            let idle = zip(try work(), idleStart).map { $0 - $1 }

            // 64 KiB each, as a busy program prints: 400 lines of 160 bytes, 10 ms apart.
            let outputStart = try work()
            let began = ContinuousClock.now
            for shell in shells {
                try await connection.send(shell.surface, text: "for i in $(seq 1 400); do printf '%0159d\\n' $i; sleep 0.01; done; echo done$((2*3))\r")
            }
            for shell in shells {
                let done = try? await connection.request(WaitForTextRequest(surface: shell.surface, pattern: "done6", timeoutMs: 30_000), timeout: .seconds(35))
                try #require(done?.matched == true, "\(shell.tab) never finished printing")
            }
            let printed = ContinuousClock.now - began
            try await Task.sleep(for: .milliseconds(2500)) // the last batch (once per wall-clock second) lands
            let output = zip(try work(), outputStart).map { $0 - $1 }

            // A hidden viewer's output comes once per wall-clock second (the daemon's hidden batch): one consumer pass and
            // one lane block per batch, and a batch may take a few reads of the socket.
            let batches = UInt64(printed.components.seconds) + 2
            let report = "printed in \(printed), at most \(batches) batches; idle \(idle); per 64 KiB \(output)"
            print("hidden-terminal-work: " + report)
            // The lead's gate (a bound from the floor): idle at most 0.2 wake chains a second; with output at most 1.5 per batch.
            for (index, work) in idle.enumerated() {
                #expect(Double(work.chains) <= 0.2 * 6, "idle hidden terminal \(index) woke its threads: \(work); \(report)")
            }
            for (index, work) in output.enumerated() {
                let perBatch = Double(work.chains) / Double(max(work.blocks, 1))
                #expect(perBatch <= 1.5, "hidden terminal \(index) started \(perBatch) wake chains per batch: \(work); \(report)")
            }
        }
    }
}
