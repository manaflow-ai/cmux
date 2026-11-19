@testable import CmuxNextSidebar
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// design/sidebar.md, "Fold defaults", with `sidebar.sessionTree` on (Leo: "Claude Code (and the Claude desktop
/// app's Code tab) shows subagents and sub-sessions nested under the parent chat"): a top-level parent starts
/// open, a parent at depth 1 or deeper starts folded, a folded parent shows a count chip of every session it
/// hides (idle ones included) beside one chip per state, and the person's folds persist per parent.
@MainActor @Suite(.serialized) struct SidebarSessionTreeFoldTests {
    private static func defaults() -> UserDefaults {
        UserDefaults(testSuiteName: "SidebarSessionTreeFoldTests.\(UUID().uuidString)") ?? .standard
    }

    /// The capture fixture's rows laid out with `tree`'s drawn folds: each drawn workspace's content.
    private static func rows(_ tree: SidebarSessionTree, filter: String? = nil) -> [(WorkspaceID, WorkspaceRowContent)] {
        let fixture = SidebarNestedFixture(scenario: .sessionTree)
        var options = SidebarLayoutOptions()
        options.sessionTree = tree.drawn
        return SidebarLayout.make(sections: fixture.sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .workspace(id) = row.key, let content = row.content { (id, content) } else { nil }
        }
    }

    private static func id(_ name: String) -> WorkspaceID { WorkspaceID("w-\(name)") }

    @Test func aTopLevelParentStartsOpenAndANestedOneStartsFolded() throws {
        let tree = SidebarSessionTree(defaults: Self.defaults())
        tree.state = SidebarSessionTreeState(parents: SidebarNestedFixture(scenario: .sessionTree).parents)
        let rows = Self.rows(tree)
        #expect(rows.map(\.0) == ["billing", "explore", "migration", "review", "rollout", "flaky", "notes"].map(Self.id))
        #expect(rows.map(\.1.treeDepth) == [0, 1, 1, 1, 1, 0, 0])
        let content = Dictionary(uniqueKeysWithValues: rows)
        #expect(content[Self.id("billing")]?.treeFold == .expanded)
        #expect(content[Self.id("billing")]?.rollUp == nil)
        // Plan the rollout started two sessions: folded by default, its count chip says 2, one of them runs.
        #expect(content[Self.id("rollout")]?.treeFold == .collapsed)
        #expect(content[Self.id("rollout")]?.rollUp == SidebarTreeRollUp(running: 1, hidden: 2))
        #expect(tree.isFolded(Self.id("rollout")))
        #expect(!tree.isFolded(Self.id("billing")))
        #expect(tree.isParent(Self.id("rollout")) && !tree.isParent(Self.id("explore")))
    }

    @Test func openingANestedParentPersistsAndFoldingItAgainForgetsIt() {
        let store = Self.defaults()
        let tree = SidebarSessionTree(defaults: store)
        let parents = SidebarNestedFixture(scenario: .sessionTree).parents
        tree.state = SidebarSessionTreeState(parents: parents)
        tree.toggle(Self.id("rollout"))
        #expect(!tree.isFolded(Self.id("rollout")))
        #expect(tree.drawn?.collapsed == [])
        #expect(Self.rows(tree).map(\.0).contains(Self.id("changelog")))
        #expect(store.stringArray(forKey: SidebarSessionTree.openedKey) == ["w-rollout"])
        // The next launch keeps it open.
        let launched = SidebarSessionTree(defaults: store)
        launched.state = SidebarSessionTreeState(parents: parents)
        #expect(!launched.isFolded(Self.id("rollout")))
        // Folding it again goes back to the default: nothing saved for it.
        launched.toggle(Self.id("rollout"))
        #expect(launched.isFolded(Self.id("rollout")))
        #expect(store.stringArray(forKey: SidebarSessionTree.openedKey) == [])
        #expect(store.stringArray(forKey: SidebarSessionTree.collapsedKey) == [])
    }

    /// A top-level parent the person folds rolls everything under it up: six sessions, one waiting on
    /// them, two running, one finished unread; the two idle ones count only in the count chip.
    @Test func aFoldedTopLevelParentCountsEverySessionItHides() throws {
        let tree = SidebarSessionTree(defaults: Self.defaults())
        tree.state = SidebarSessionTreeState(parents: SidebarNestedFixture(scenario: .sessionTree).parents)
        tree.toggle(Self.id("billing"))
        let rows = Self.rows(tree)
        #expect(rows.map(\.0) == ["billing", "flaky", "notes"].map(Self.id))
        let billing = try #require(rows.first?.1)
        #expect(billing.treeFold == .collapsed)
        #expect(billing.rollUp == SidebarTreeRollUp(blocked: 1, running: 2, unread: 1, hidden: 6))
    }

    /// A fold of idle sessions only still shows its count chip (before, it drew no roll-up at all).
    @Test func aFoldOfIdleSessionsShowsItsCount() {
        let a = WorkspaceID("a"), b = WorkspaceID("b"), c = WorkspaceID("c")
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: a, title: "a")), .workspace(SidebarWorkspace(id: b, title: "b")),
            .workspace(SidebarWorkspace(id: c, title: "c")),
        ])]
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState(parents: [b: a, c: a], collapsed: [a])
        let row = SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.first { $0.key == .workspace(a) }
        #expect(row?.content?.rollUp == SidebarTreeRollUp(hidden: 2))
        #expect(CmuxNextSidebar.Strings.rollUp(SidebarTreeRollUp(hidden: 2)).contains("2"))
    }

    /// Selecting a session a default fold hides opens that fold and remembers it, as a person's own open would.
    @Test func revealingASessionUnderADefaultFoldOpensIt() {
        let tree = SidebarSessionTree(defaults: Self.defaults())
        tree.state = SidebarSessionTreeState(parents: SidebarNestedFixture(scenario: .sessionTree).parents)
        #expect(tree.drawn?.hidesInFold(Self.id("changelog")) == true)
        tree.reveal(Self.id("changelog"))
        #expect(tree.opened == [Self.id("rollout")])
        #expect(tree.drawn?.hidesInFold(Self.id("changelog")) == false)
    }

    /// The tree off draws nothing nested, whatever folds are saved; on again, the saved folds come back.
    @Test func turningTheTreeOffAndOnKeepsTheFolds() {
        let tree = SidebarSessionTree(defaults: Self.defaults())
        let parents = SidebarNestedFixture(scenario: .sessionTree).parents
        tree.state = SidebarSessionTreeState(parents: parents)
        tree.toggle(Self.id("billing"))
        tree.state = nil
        #expect(tree.drawn == nil)
        #expect(Self.rows(tree).allSatisfy { $0.1.treeDepth == 0 && $0.1.treeFold == nil })
        tree.state = SidebarSessionTreeState(parents: parents)
        #expect(tree.drawn?.collapsed.contains(Self.id("billing")) == true)
    }
}
