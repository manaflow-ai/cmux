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
}
