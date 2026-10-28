import AppKit
@testable import CmuxNextApp
import CmuxNextFeatures
import CmuxNextMemory
import Foundation
import Testing

/// Audit H8: a window parks every workspace it showed (views, panes, observations stay mounted). With
/// `memoryDiscardParkedWorkspaces` at its default (off), nothing but critical memory pressure released
/// them, so a person who visited 200 workspaces kept 200 mounted. Closing or leaving something releases
/// what it owns in bounded time; only a cache with an explicit budget stays. The parked workspaces are
/// that cache: at most `SubsystemBudget.parkedWorkspaces` of them, with the switch on or off, and past
/// it the least recently shown one is torn down and freed, as Chrome's back-forward cache evicts its
/// least recently used entry past its size (content/browser/renderer_host/back_forward_cache_impl.cc).
@MainActor @Suite(.serialized)
struct ParkedWorkspaceCapTests {
    final class Sentinel {
        weak var content: WorkspaceContentController?
        init(_ content: WorkspaceContentController?) { self.content = content }
    }

    @Test(.timeLimit(.minutes(2)))
    func pastTheCapTheLeastRecentlyShownParkedWorkspacesAreFreed() async throws {
        let cap = SubsystemBudget.forThisMac(gpuResidentAvailable: false).parkedWorkspaces
        let over = 2
        // k0 shows first; visiting k1 ... k(cap + over) parks k0 ... k(cap + over - 1): `over` past the cap.
        let bench = try await SpaceSwitchBench(total: cap + over + 1, spaces: 1)
        defer { bench.close() }
        #expect(!bench.services.features.isEnabled(.memoryDiscardParkedWorkspaces), "the switch is not at its default (off)")
        let keys = try #require(bench.keysByRoom[bench.rooms[0]])  // k0 ... k(cap + over), in order
        var sentinels: [String: Sentinel] = [:]
        for key in keys.dropFirst() {
            autoreleasepool {
                if let shown = bench.controller.content { sentinels[shown.workspace.id] = Sentinel(shown) }
                bench.services.windows.select(key, in: bench.state)
                bench.controller.showWorkspace(requested: bench.state.workspaceID)
            }
            bench.drain()
        }
        #expect(bench.controller.content?.workspace.id == keys.last, "the last visit did not show its workspace")

        // The budget's look runs as background work after the switch's turn, one teardown per look.
        _ = runMainLoop { bench.controller.parked.count <= cap }
        let parked = Set(bench.controller.parked.keys)
        #expect(parked.count <= cap, "\(parked.count) workspaces stay parked past the cap of \(cap)")
        let oldest = Array(keys.prefix(over)), newest = Set(keys.dropLast().suffix(cap))
        #expect(parked == newest, "the parked ones are not the \(cap) most recently shown: \(parked.sorted())")

        // A released workspace frees its content controller (its views, panes and observations with it).
        for _ in 0..<40 { await Task.yield() }
        bench.drain()
        let alive = oldest.filter { sentinels[$0]?.content != nil }
        #expect(alive.isEmpty, "the least recently shown workspaces are still alive: \(alive)")
    }
}
