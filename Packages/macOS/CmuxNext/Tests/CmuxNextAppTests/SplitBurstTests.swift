import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// Lawrence 2026-10-23: "spamming a bunch of cmd shift d and cmd d etc is laggy ish". Every split
/// press in a burst shows its pane in the key's turn and the daemon makes every one of them: a press
/// on a pane still being created (its stand-in) splits that pane, never a pane the daemon does not
/// know. Runs the app's Split Right against a same-tree cmux-tui daemon.
/// The refusals the app showed while a test ran.
@MainActor private final class SeenRefusals {
    var reasons: [String] = []
}

/// One wait's continuation, resumed once: by the observation's change or at once when the condition holds.
@MainActor private final class OneResume {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ holds: Bool) {
        continuation?.resume(returning: holds)
        continuation = nil
    }
}

/// Returns once `condition` holds, waking on each change of an observable value it reads (the window's layout
/// model, the store's records) or of the store's applied sequence: an event, never a timer. The suite's time
/// limit bounds a wait for a change that never comes.
@MainActor private func whenObserved(_ store: DaemonStore, _ condition: @escaping @MainActor () -> Bool) async {
    while true {
        let holds = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OneResume(continuation)
            let now = withObservationTracking {
                _ = store.appliedSequence
                return condition()
            } onChange: {
                // Runs inside the mutation: look again once it landed.
                Task { @MainActor in once.resume(false) }
            }
            if now { once.resume(true) }
        }
        if holds { return }
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBurstTests {
    /// Cmd-D, then at once (same turn) Cmd-Shift-D on the pane it is creating: the second split goes to the
    /// daemon's pane for that stand-in, so both new panes stay. Before: the second command named the
    /// stand-in's handle, the daemon refused it, and its pane vanished (a lost press).
    @Test func cmdDOnAPaneStillBeingCreatedSplitsIt() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            let creating = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split showed no pane in its turn")
            #expect(creating.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the first split is still being created")
            let seen = SeenRefusals()
            let shown = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in seen.reasons.append(reason); shown?(reason, quiet) }
            // Down, so the room check is the stand-in's height, not a third column's width.
            let onStandIn = ActionInvocation(target: ActionTargetRef(kind: .pane, id: creating.pane.id), origin: .user)
            var performed = false
            let work = services.registry.capturingWork { performed = services.registry.perform("splitDown", invocation: onStandIn) }
            #expect(performed)
            #expect(content.panes.count == before.count + 2, "the second split showed no pane in its turn; refusals \(seen.reasons)")
            @MainActor func confirmed() -> Int {
                content.panes.values.filter { $0.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }.count
            }
            let store = services.daemon.store
            // The window's panes follow its layout model (observable), which follows the store.
            @MainActor func shownPanes() -> Int {
                _ = content.layoutModel.screens
                return content.panes.count
            }
            // The second split's own outcome: nil, or why it failed.
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "the split of the stand-in failed: \(failures)")
            // A lost press never gets here: the suite's time limit fails the wait (refusals: `seen.reasons`).
            await whenObserved(store) { shownPanes() == before.count + 2 && confirmed() == before.count + 2 }
            // And they stay: once every intent left the store's log (the daemon's echo and layout
            // applied, nothing left to take a pane back), both new panes are still there.
            await whenObserved(store) { store.pendingIntents.isEmpty }
            await whenObserved(store) { shownPanes() == before.count + 2 }
            #expect(confirmed() == before.count + 2, "refusals \(seen.reasons)")
        }
    }
}
