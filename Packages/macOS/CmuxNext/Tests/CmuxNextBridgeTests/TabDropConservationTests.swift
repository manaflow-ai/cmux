import CmuxNextDaemon
import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

/// Dogfood: "dragging tab and dropping into its own pane has a bug where the
/// tab/terminal pane just entirely disappears". Tagged build tdrag2: a tab
/// dropped on its own pane's center was a move into its own strip; the
/// daemon kept the tab, the app's strip kept hiding it forever.
///
/// Tab conservation: no drop changes the set of tabs; a drop onto the
/// tab's own place is no operation (it springs back); every drag ends its
/// presentation.
struct TabDropConservationTests {
    let strip = UUID()

    private func context(paneTabs: Int, index: Int) -> TabDragContext {
        TabDragContext(sourcePaneID: "pane-a", sourcePaneTabCount: paneTabs, sourceWorkspaceID: "ws-1",
                       sourceWorkspaceTabCount: paneTabs + 2, draggedTabCount: 1, sourceStripID: strip, sourceIndex: index)
    }

    private func outcome(_ kind: TabDropKind, _ context: TabDragContext) -> TabDragOutcome {
        TabDragResolver.outcome(for: TabDropProposal(kind: kind, highlightFrame: .zero), insideWindow: true, screenPoint: .zero,
                                context: context)
    }

    /// The pane-center target proposes "end of the pane's strip": for the
    /// pane's only tab that is where it already is.
    @Test func droppingTheOnlyTabOnItsOwnPaneIsNoOperation() {
        #expect(outcome(.strip(stripID: strip, index: 1, groupID: nil), context(paneTabs: 1, index: 0)) == .cancel)
    }

    @Test func droppingATabOnItsOwnSlotIsNoOperation() {
        let ctx = context(paneTabs: 3, index: 1)
        #expect(outcome(.strip(stripID: strip, index: 1, groupID: nil), ctx) == .cancel)
        // The last tab onto the pane center ("end of strip"): the same slot.
        #expect(outcome(.strip(stripID: strip, index: 3, groupID: nil), context(paneTabs: 3, index: 2)) == .cancel)
        // A real reorder in its own strip is still a move.
        #expect(outcome(.strip(stripID: strip, index: 2, groupID: nil), ctx) == .strip(stripID: strip, index: 2, groupID: nil))
        // Joining a group in place is a real change.
        #expect(outcome(.strip(stripID: strip, index: 1, groupID: "g"), ctx) == .strip(stripID: strip, index: 1, groupID: "g"))
    }

    @Test func aSettledDragReleasesItsPresentation() throws {
        var releases = 0, restores = 0
        let lifecycle = TabDragLifecycle(restore: { restores += 1 }, release: { releases += 1 })
        let transaction = try #require(lifecycle.beginCommit())
        lifecycle.settle(transaction, ok: true)
        lifecycle.settle(transaction, ok: true)
        #expect(releases == 1)
        #expect(restores == 0)
    }

    @Test func everyEndReleasesExactlyOnce() throws {
        var releases = 0
        let cancelled = TabDragLifecycle(restore: {}, release: { releases += 1 })
        cancelled.cancel()
        cancelled.cancel()
        #expect(releases == 1)
        let rejected = TabDragLifecycle(restore: {}, release: { releases += 1 })
        let transaction = try #require(rejected.beginCommit())
        rejected.settle(transaction, ok: false)
        #expect(releases == 2)
    }
}

/// Seeded property test: random layouts, a random dragged tab and a random
/// drop target of every kind (own pane, own slot, every edge, other panes,
/// other workspaces, outside every window). The resolver's outcome, applied
/// to the reference `LayoutModel`, must keep every layout invariant, never
/// be a move to the tab's own place (that is `.cancel`), and never name a
/// target the layout rejects.
struct TabDropPropertyTests {
    /// SplitMix64: deterministic, so a failure names its seed.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let cases = 20_000

    func randomLayout(_ rng: inout Random) -> LayoutModel {
        var tab = 0
        let workspaces = (0..<Int.random(in: 1...3, using: &rng)).map { w in
            LayoutModel.Workspace(id: "w\(w)", panes: (0..<Int.random(in: 1...3, using: &rng)).map { p in
                LayoutModel.Pane(id: "w\(w)p\(p)", tabs: (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                    tab += 1
                    return "t\(tab)"
                })
            })
        }
        return LayoutModel(workspaces: workspaces)
    }

    func randomKind(_ model: LayoutModel, _ rng: inout Random) -> TabDropKind {
        let panes = model.workspaces.flatMap(\.panes)
        let pane = panes.randomElement(using: &rng)!
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: return .strip(stripID: pane.stripID, index: Int.random(in: 0...(pane.tabs.count + 1), using: &rng),
                              groupID: Bool.random(using: &rng) ? nil : "g")
        case 1: return .newSplit(paneID: pane.id, edge: [TabDropEdge.left, .right, .top, .bottom].randomElement(using: &rng)!)
        case 2: return .newColumn(screenID: "s", afterColumnID: Bool.random(using: &rng) ? "c" : nil)
        case 3: return .newWorkspace(groupID: nil, index: Int.random(in: -1...3, using: &rng))
        default: return .workspace(id: model.workspaces.randomElement(using: &rng)!.id)
        }
    }

    @Test func noDropLosesDuplicatesOrStrandsATab() {
        var rng = Random(state: 0xC0FFEE)
        var applied = 0, cancelled = 0
        for run in 0..<Self.cases {
            let model = randomLayout(&rng)
            let tab = model.allTabs.randomElement(using: &rng)!
            guard var context = model.context(dragging: tab, windowWorkspaceCount: Int.random(in: 1...2, using: &rng)) else {
                Issue.record("run \(run): no context")
                return
            }
            let respawns = Bool.random(using: &rng)
            context.respawnsOnSplit = respawns
            let inside = Int.random(in: 0..<8, using: &rng) != 0
            let kind = randomKind(model, &rng)
            let outcome = TabDragResolver.outcome(for: TabDropProposal(kind: kind, highlightFrame: .zero), insideWindow: inside,
                                                  screenPoint: .zero, context: context)
            if case .strip(let stripID, let index, let group) = outcome, stripID == context.sourceStripID, group == nil {
                let final = min(index, context.sourcePaneTabCount - 1)
                if final == context.sourceIndex {
                    Issue.record("run \(run): a move of \(tab) to its own place (\(index)) instead of no operation")
                    return
                }
            }
            guard let after = model.applying(outcome, dragging: tab, respawns: respawns) else {
                Issue.record("run \(run): \(outcome) for \(tab) names a target the layout rejects (\(model.workspaces))")
                return
            }
            let violations = LayoutInvariants.violations(before: model, after: after)
            if !violations.isEmpty {
                Issue.record("run \(run): \(outcome) for \(tab): \(violations)")
                return
            }
            if outcome == .cancel { cancelled += 1 } else { applied += 1 }
        }
        #expect(applied > Self.cases / 4)
        #expect(cancelled > 0)
    }
}
