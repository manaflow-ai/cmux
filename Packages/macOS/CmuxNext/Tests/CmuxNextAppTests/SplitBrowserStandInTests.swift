import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Split Browser Right/Down shows its new pane in the key's own turn (zero-latency.md, "Native actions:
/// the budget contract"): before, it was a `.waiting(.daemonEcho)` effect and nothing showed until the
/// daemon had opened the tab and moved it to a split. The pane holds a stand-in browser tab, and the
/// daemon's pane takes its place once the move lands; the run is never counted as waiting.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBrowserStandInTests {
    private static func panes(_ services: AppServices) -> [PaneModel] {
        services.daemon.store.workspaces.first?.screens.first?.panes ?? []
    }

    private static func describe(_ services: AppServices) -> String {
        "\(panes(services).map { ($0.handle.rawValue, $0.tabs.map(\.surface.rawValue)) })"
    }

    @Test(arguments: ["splitBrowserRight", "splitBrowserDown"])
    func theNewPaneShowsInTheActionsTurnAndTheDaemonsPaneTakesItsPlace(action: String) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let model = try #require(Self.panes(services).first)
            let before = Self.panes(services).count, old = Set(Self.panes(services).map(\.handle))
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: model.id), origin: .cli)
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform(ActionID(rawValue: action), invocation: invocation)
                }
            }
            #expect(refusal == nil, "the split was refused: \(refusal ?? "")")
            // Read in the action's own turn: nothing was awaited since the perform.
            let shown = Self.panes(services)
            #expect(shown.count == before + 1, "no new pane in the action's turn: \(Self.describe(services))")
            let standIn = shown.first { !old.contains($0.handle) }
            #expect(standIn?.tabs.count == 1 && standIn?.tabs.first?.kind == .browser, "the new pane holds no browser tab: \(Self.describe(services))")
            #expect(services.registry.waitingRuns[ActionID(rawValue: action)] == nil, "the run was counted as showing nothing until the reply")
            for task in work {
                let failure = await task.value
                #expect(failure == nil, "the split failed: \(failure?.message ?? "")")
            }
            // The daemon's pane takes the stand-in's place: one new pane, holding the daemon's browser tab.
            try await PinnedPageTests.until({
                let panes = Self.panes(services)
                return panes.count == before + 1
                    && panes.allSatisfy { $0.tabs.allSatisfy { !ProvisionalTab.isProvisional(surface: $0.surface) } }
                    && panes.contains { !old.contains($0.handle) && $0.tabs.count == 1 && $0.tabs.first?.kind == .browser }
            }, report: { Self.describe(services) })
        }
    }
    /// The person closes the new pane before the daemon made it (the review of 784e13f2bf6): the
    /// creation's intent leaves the log once the daemon's close of the tab committed, so
    /// `waitIntentsIdle` (every socket action's settle) returns instead of waiting for ever.
    @Test func aSplitClosedBeforeTheDaemonMadeItLeavesTheIntentLog() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let model = try #require(Self.panes(services).first)
            let old = Set(Self.panes(services).map(\.handle))
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: model.id), origin: .cli)
            let work = services.registry.capturingWork {
                _ = services.registry.perform("splitBrowserRight", invocation: invocation)
            }
            let standIn = try #require(Self.panes(services).first { !old.contains($0.handle) }, "no new pane: \(Self.describe(services))")
            #expect(store.creations.cancel(pane: standIn.handle), "the new pane is not a pending split")
            for task in work { _ = await task.value }
            try await PinnedPageTests.until({ store.pendingIntents.isEmpty }, report: { "\(store.pendingIntents.map(\.intent.caseName))" })
            #expect(await store.waitIntentsIdle())
            #expect(Set(Self.panes(services).map(\.handle)) == old, "the closed split left a pane: \(Self.describe(services))")
            #expect(Self.panes(services).allSatisfy { $0.tabs.allSatisfy { $0.kind != .browser } }, "the closed split's tab is still open: \(Self.describe(services))")
        }
    }
}
