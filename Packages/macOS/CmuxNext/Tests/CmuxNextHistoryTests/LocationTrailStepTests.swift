import CmuxNextHistory
import Foundation
import Testing

/// BACK-FORWARD-WORKSPACES-ONLY (Lawrence: "app back/forth should only nav
/// between workspaces by default"): with workspace steps, focus changes
/// inside a workspace are not steps; the workspace's entry remembers the
/// tab it last had focused. Top pages are steps. `everything` keeps every
/// tab and pane focus as a step.
struct LocationTrailStepTests {
    static let t0 = Date(timeIntervalSince1970: 4_000_000)

    static func tab(_ id: String, workspace: String) -> HistoryLocation {
        HistoryLocation(key: .init(machine: "home", tab: id), window: "w1", workspace: workspace, pane: "p-\(id)", content: .terminal, title: id)
    }

    static func trail(_ locations: [HistoryLocation], scope: HistoryStepScope) -> LocationTrail {
        var trail = LocationTrail()
        for (index, location) in locations.enumerated() {
            trail.record(location, at: t0.addingTimeInterval(Double(index) * 2), scope: scope)
        }
        return trail
    }

    @Test func focusInsideAWorkspaceIsNotAStepAndBackReturnsToItsLastTab() {
        var trail = Self.trail([Self.tab("a1", workspace: "A"), Self.tab("a2", workspace: "A"), Self.tab("b1", workspace: "B")],
                               scope: .workspaces)
        #expect(trail.entries.map(\.location.key.tab) == ["a2", "b1"], "one step per workspace")
        #expect(trail.back(scope: .window)?.location.key.tab == "a2", "back to workspace A, at the tab it last had focused")
    }

    @Test func topPagesAreSteps() {
        let trail = Self.trail([Self.tab("a1", workspace: "A"), .page("home", window: "w1", title: "Home"),
                                .page("page:app-store", window: "w1", title: "App Store"), Self.tab("a2", workspace: "A")],
                               scope: .workspaces)
        #expect(trail.entries.map { $0.location.page ?? $0.location.key.tab } == ["a1", "home", "page:app-store", "a2"])
    }

    @Test func everythingKeepsEveryFocusAsAStep() {
        let trail = Self.trail([Self.tab("a1", workspace: "A"), Self.tab("a2", workspace: "A"), Self.tab("b1", workspace: "B")],
                               scope: .everything)
        #expect(trail.entries.map(\.location.key.tab) == ["a1", "a2", "b1"])
    }

    @Test func workspacesIsTheDefault() {
        #expect(HistoryStepScope.default == .workspaces)
    }
}
