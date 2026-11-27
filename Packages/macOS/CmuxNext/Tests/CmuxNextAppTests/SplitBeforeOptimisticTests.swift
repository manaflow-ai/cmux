import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// Split Up and Split Left show in the key's turn and never move after it (Leo 2026-11-08, on a bottom pane opening
/// upward: "target gets recalculated ... shit lags"). They used to wait for the daemon: `split` put the new pane after
/// its target, `swap-pane` then traded the two, so the window retargeted its springs at the reply and again at the
/// swap. With `split-before-v1` the same-tree daemon makes the split with the new pane first, so the command takes
/// the optimistic path: the store shows the split in the key's turn, the daemon's layout is that same split (side,
/// ratio, public ids), and no `swap-pane` goes out, so the shown order never flips.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBeforeOptimisticTests {
    /// The split node of `target`'s screen whose sides are leaves holding `target`: direction, ratio, public id and
    /// the two panes' public ids in order. Nil when no such split shows.
    private struct Shown: Equatable {
        var direction: SplitDirection
        var ratio: Double
        var split: String?
        var panes: [String?]
    }

    private static func shown(around target: PaneID, in store: DaemonStore) -> Shown? {
        func find(_ node: LayoutNode) -> Shown? {
            guard case let .split(_, resourceID, direction, ratio, a, b) = node else { return nil }
            if case let .leaf(first) = a, case let .leaf(second) = b, first == target || second == target {
                let ids = [first, second].map { store.panesByHandle[$0]?.resourceID?.rawValue }
                return Shown(direction: direction, ratio: (ratio * 1000).rounded() / 1000, split: resourceID?.rawValue, panes: ids)
            }
            return find(a) ?? find(b)
        }
        return store.screen(containing: target).flatMap { find($0.layout) }
    }

    private static func eventually(within timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// Split Up (`down`, the original pane moves down) and Split Left (`right`, the original pane moves right).
    @Test(arguments: zip([SplitDirection.down, .right], [PaneDirection.down, .right]))
    func aSplitUpOrLeftShowsTheDaemonsLayoutInTheKeysTurn(direction: SplitDirection, swap: PaneDirection) async throws {
        try await AppHarnessWindows.withApp { services, _ in
            let daemon = services.daemon
            try #require(daemon.supports(DaemonCapability.splitBefore.rawValue), "the same-tree daemon serves split-before-v1")
            let first = try #require(daemon.store.panesByHandle.values.first {
                $0.handle.rawValue < ProvisionalPane.firstHandle && !$0.tabs.isEmpty
            }, "the app has a daemon pane")
            // A terminal pane of its own to split (the harness's first pane may sit beside a chat): a plain Cmd-D.
            let made = ProvisionalPane()
            _ = try await PaneSplitCommand(pane: first.handle, direction: .right, options: SpawnOptions(), swapTowards: nil)
                .intendNow(on: daemon, provisional: made)()
            let target = try #require(daemon.store.index.panesByResource[ResourceID(rawValue: made.paneID)]?.handle)
            let targetID = try #require(daemon.store.panesByHandle[target]?.resourceID?.rawValue)
            #expect(await Self.eventually { daemon.store.screen(containing: target)?.layout.paneIDs.contains(target) == true })

            let command = PaneSplitCommand(pane: target, direction: direction, options: SpawnOptions(), swapTowards: swap)
            #expect(command.isOptimistic(on: daemon), "Split Up/Left waits for the daemon")
            #expect(command.placesBefore(on: daemon))
            let provisional = ProvisionalPane()
            let send = command.intendNow(on: daemon, provisional: provisional)
            // The key's turn: the new pane shows before its target, under the ids the daemon will use.
            let atKey = Shown(direction: direction, ratio: 0.5, split: provisional.splitID, panes: [provisional.paneID, targetID])
            #expect(Self.shown(around: target, in: daemon.store) == atKey, "the key's turn shows \(String(describing: Self.shown(around: target, in: daemon.store)))")

            // Every state the store shows until the daemon's layout places its pane and a while after: one split, never
            // flipped (a `swap-pane` would trade the two sides), never resized.
            var seen: [Shown?] = []
            let created = Task { @MainActor in try await send() }
            let placed = await Self.eventually {
                seen.append(Self.shown(around: target, in: daemon.store))
                guard let pane = daemon.store.index.panesByResource[ResourceID(rawValue: provisional.paneID)],
                      pane.handle.rawValue < ProvisionalPane.firstHandle else { return false }
                return daemon.store.screen(containing: pane.handle)?.layout.paneIDs.contains(pane.handle) == true
            }
            _ = try await created.value
            #expect(placed, "the daemon's layout never placed the new pane")
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(10))
                seen.append(Self.shown(around: target, in: daemon.store))
            }
            #expect(seen.allSatisfy { $0 == atKey }, "the split changed after the key's turn: \(seen.filter { $0 != atKey })")
        }
    }
}
