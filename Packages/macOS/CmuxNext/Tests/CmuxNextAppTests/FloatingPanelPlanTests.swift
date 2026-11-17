import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// Floating panes as panels of the app window (`FloatingPanelPlan`): which panels show for which workspace, and the
/// steps from one plan to the next, by counts.
///
/// A window here has 3 workspaces: `one` with 2 floating panes, `two` with 1 and `three` with none. The walk of a
/// switch applies the steps one at a time to a model of the display (the workspaces of the content and the panels
/// that show) and counts, after each step, the panels of a workspace that the content does not show.
@MainActor struct FloatingPanelPlanTests {
    typealias Plan = FloatingPanelPlan

    let a: PaneID = "a", b: PaneID = "b", c: PaneID = "c", q: PaneID = "q"
    let area = CGRect(x: 100, y: 200, width: 1000, height: 800)
    let display = CGRect(x: 0, y: 0, width: 1600, height: 1200)

    func pane(_ pane: PaneID, _ x: CGFloat = 0.25, _ y: CGFloat = 0.25) -> LayoutFloatingPane {
        LayoutFloatingPane(pane: pane, frame: CGRect(x: x, y: y, width: 0.5, height: 0.5))
    }

    func content(_ workspace: String, _ floating: [LayoutFloatingPane], shown: Bool = true, covered: Bool = false,
                 hidden: Set<PaneID> = [], elsewhere: Set<PaneID> = []) -> Plan.Content {
        Plan.Content(workspace: workspace, isShown: shown, isCovered: covered, floating: floating, hidden: hidden,
                     elsewhere: elsewhere, area: area)
    }

    /// The window's plan while it shows `shown` of the 3 workspaces.
    func window(showing shown: Set<String>) -> Plan {
        Plan(contents: [
            content("one", [pane(a), pane(b, 0.3, 0.3)], shown: shown.contains("one")),
            content("two", [pane(c)], shown: shown.contains("two")),
            content("three", [], shown: shown.contains("three")),
        ], displays: [display], scale: 2)
    }

    func plan(_ contents: Plan.Content...) -> Plan { Plan(contents: contents, displays: [display], scale: 2) }

    func count(_ steps: [Plan.Step], _ kind: Plan.Step.Kind) -> Int { steps.count { $0.kind == kind } }

    // MARK: Which panels show

    @Test func aWorkspaceShowsItsOwnPanelsAndNoOther() {
        let expected = ["one": 2, "two": 1, "three": 0]
        for (workspace, panels) in expected {
            let plan = window(showing: [workspace])
            #expect(plan.panels.count == panels, "\(workspace)")
            #expect(plan.panels.count { $0.workspace != workspace } == 0, "\(workspace)")
            #expect(plan.kept.count == 3 - panels, "each floating pane that does not show keeps its panel")
            #expect(plan.workspaces == [workspace])
        }
        #expect(window(showing: ["one"]).panels.map(\.pane) == [a, b], "back to front, the order of the list")
    }

    @Test func noWorkspaceShownMeansNoPanel() {
        let plan = window(showing: [])
        #expect(plan.panels.isEmpty)
        #expect(plan.kept == [a, b, c])
        #expect(plan.workspaces.isEmpty)
    }

    @Test func twoWorkspacesSideBySideShowThePanelsOfBoth() {
        let plan = window(showing: ["one", "two"])
        #expect(plan.panels.map(\.pane) == [a, b, c])
        #expect(plan.panels.map(\.workspace) == ["one", "one", "two"])
        #expect(plan.kept.isEmpty)
    }

    @Test func aCoveredContentShowsNoPanelAndKeepsEachOne() {
        let covered = plan(content("one", [pane(a), pane(b)], covered: true))
        #expect(covered.panels.isEmpty)
        #expect(covered.kept == [a, b])
        #expect(covered.workspaces == ["one"])
    }

    @Test func aPaneOfTheListShowsOneTime() {
        let twice = plan(content("one", [pane(a), pane(b), pane(a, 0.4, 0.4)]))
        #expect(twice.panels.map(\.pane) == [a, b], "the first entry of a pane is its entry")
    }

    // MARK: A switch of the workspace

    /// The panels of a workspace that the content does not show, counted after each step of `steps`.
    func strangers(after steps: [Plan.Step], from start: Plan, owner: [PaneID: String]) -> [Int] {
        var workspaces = Set(start.workspaces), showing = Set(start.panels.map(\.pane)), counts: [Int] = []
        for step in steps {
            switch step {
            case let .leave(pane), let .dissolve(pane): showing.remove(pane)
            case let .commit(next): workspaces = Set(next)
            case let .arrive(pane, _): showing.insert(pane)
            case .move, .order: break
            }
            counts.append(showing.count { pane in owner[pane].map { workspaces.contains($0) } != true })
        }
        return counts
    }

    @Test func aSwitchNeverShowsAPanelOfAnotherWorkspace() {
        let owner: [PaneID: String] = [a: "one", b: "one", c: "two"]
        let floating = ["one": 2, "two": 1, "three": 0]
        let order = ["one", "two", "three", "one", "three", "two", "one", "two", "two", "three", "three", "one"]
        var from = window(showing: []), last: String?, switches = 0, wrong = 0
        for workspace in order {
            let to = window(showing: [workspace]), steps = to.steps(from: from)
            let old = last.flatMap { floating[$0] } ?? 0, new = floating[workspace] ?? 0
            if last == workspace {
                #expect(steps.isEmpty, "the same workspace again: nothing to do")
            } else {
                switches += 1
                #expect(count(steps, .commit) == 1)
                #expect(count(steps, .leave) == old, "each panel of the old workspace leaves")
                #expect(count(steps, .arrive) == new, "each panel of the new workspace arrives")
                #expect(count(steps, .dissolve) == 0, "a switch ends no floating pane")
                #expect(count(steps, .move) == 0)
                // Each leave is before the commit, and each arrival is after it.
                let commit = steps.firstIndex { $0.kind == .commit } ?? -1
                #expect(steps.prefix(max(commit, 0)).allSatisfy { $0.kind == .leave })
                #expect(steps.suffix(from: commit + 1).allSatisfy { $0.kind == .arrive || $0.kind == .order })
            }
            wrong += strangers(after: steps, from: from, owner: owner).reduce(0, +)
            from = to
            last = workspace
        }
        #expect(switches == 10)
        #expect(wrong == 0, "0 panels of another workspace after each step of each switch")
    }

    @Test func aSwitchBetweenTwoPairsOfWorkspacesMovesOnlyTheOnesThatChange() {
        let steps = window(showing: ["two", "three"]).steps(from: window(showing: ["one", "two"]))
        #expect(steps == [.leave(a), .leave(b), .commit(["two", "three"])], "the panel of `two` stays as it is")
    }

    // MARK: A change of the list

    @Test func aPaneThatBeginsToFloatArrivesAndOneThatEndsDissolves() {
        let one = plan(content("one", [pane(a)])), two = plan(content("one", [pane(a), pane(b, 0.3, 0.3)]))
        let arrival = two.steps(from: one)
        #expect(arrival == [.arrive(b, frame: two.panels[1].frame)], "above each panel that shows: no order step")
        let end = one.steps(from: two)
        #expect(end == [.dissolve(b)])
        #expect(plan(content("one", [])).steps(from: two).map(\.kind) == [.dissolve, .dissolve])
    }

    @Test func aNewFrameIsOneMoveAndANewOrderIsOneOrder() {
        let before = plan(content("one", [pane(a), pane(b, 0.3, 0.3)]))
        let moved = plan(content("one", [pane(a), pane(b, 0.4, 0.3)]))
        #expect(moved.steps(from: before) == [.move(b, frame: moved.panels[1].frame)])
        let raised = plan(content("one", [pane(b, 0.3, 0.3), pane(a)]))
        #expect(raised.steps(from: before) == [.order([b, a])])
        #expect(before.steps(from: before).isEmpty)
    }

    @Test func aPanelThatArrivesUnderAnotherGetsOneOrderStep() {
        let before = plan(content("one", [pane(b, 0.3, 0.3)])), after = plan(content("one", [pane(a), pane(b, 0.3, 0.3)]))
        #expect(after.steps(from: before) == [.arrive(a, frame: after.panels[0].frame), .order([a, b])])
    }

    // MARK: A pane that leaves and comes back

    @Test func aHiddenPaneLeavesAndComesBackWithItsPanel() {
        let shown = plan(content("one", [pane(a), pane(q, 0.5, 0.5)]))
        let hidden = plan(content("one", [pane(a), pane(q, 0.5, 0.5)], hidden: [q]))
        #expect(hidden.panels.map(\.pane) == [a])
        #expect(hidden.kept == [q], "its place in the list and its panel stay")
        let hide = hidden.steps(from: shown), show = shown.steps(from: hidden)
        #expect(hide == [.leave(q)])
        #expect(show == [.arrive(q, frame: shown.panels[1].frame)])
        var steps: [Plan.Step] = []
        for _ in 0..<5 { steps += hide + show }
        #expect(count(steps, .leave) == 5 && count(steps, .arrive) == 5)
        #expect(count(steps, .dissolve) == 0, "a hide ends no floating pane")
        #expect(count(steps, .commit) == 0, "a hide is no change of the content")
    }

    @Test func aPaneOfAnotherScreenKeepsItsPanel() {
        let first = plan(content("one", [pane(a)], elsewhere: [b])), second = plan(content("one", [pane(b)], elsewhere: [a]))
        #expect(first.kept == [b])
        #expect(second.steps(from: first) == [.leave(a), .arrive(b, frame: second.panels[0].frame)])
        #expect(count(second.steps(from: first), .commit) == 0, "the same workspace")
    }

    @Test func aPaneThatEndsWhileItIsAwayDissolves() {
        let parked = plan(content("one", [pane(a), pane(b)], shown: false))
        #expect(plan(content("one", [pane(a)], shown: false)).steps(from: parked) == [.dissolve(b)])
        #expect(plan().steps(from: parked).map(\.kind) == [.dissolve, .dissolve], "the workspace closed")
    }

    // MARK: The frame

    @Test func aFrameIsItsFractionsOfTheAreaFromTheTopLeft() {
        let frame = FloatingPanelFrame.frame(of: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), in: area, scale: 2)
        #expect(frame == CGRect(x: 350, y: 400, width: 500, height: 400))
        #expect(plan(content("one", [pane(a)])).panels.first?.frame == frame)
        // The whole area: the area itself.
        #expect(FloatingPanelFrame.frame(of: CGRect(x: 0, y: 0, width: 1, height: 1), in: area, scale: 2) == area)
    }

    @Test func aFrameCanLeaveTheArea() {
        let left = FloatingPanelFrame.frame(of: CGRect(x: -0.25, y: 0.5, width: 0.5, height: 0.25), in: area, scale: 1)
        #expect(left == CGRect(x: -150, y: 400, width: 500, height: 200), "a quarter of the area's width left of it")
        let below = FloatingPanelFrame.frame(of: CGRect(x: 0.5, y: 1.125, width: 0.25, height: 0.25), in: area, scale: 1)
        #expect(below == CGRect(x: 600, y: -100, width: 250, height: 200), "under the area's bottom edge")
        for frame in [left, below] {
            let back = FloatingPanelFrame.fractions(of: frame, in: area)
            #expect(FloatingPanelFrame.frame(of: back, in: area, scale: 1) == frame, "the fractions of a frame give the frame again")
        }
    }

    @Test func eachEdgeOfAFrameIsOnThePixelGrid() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 801)
        let frame = FloatingPanelFrame.frame(of: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), in: odd, scale: 2)
        for value in [frame.minX, frame.maxX, frame.minY, frame.maxY] {
            #expect((value * 2).rounded() == value * 2, "\(value)")
        }
        #expect(FloatingPanelFrame.fractions(of: frame, in: .zero) == CGRect(x: 0, y: 0, width: 1, height: 1), "an area with no size")
    }

    // MARK: The frame that shows stays in reach

    @Test func aFrameWithItsBarOnADisplayStaysAsItIs() {
        let inside = CGRect(x: 300, y: 300, width: 400, height: 300)
        #expect(FloatingPanelFrame.reachable(inside, displays: [display]) == inside)
        // Partly off the display, 40 points of the bar still on it.
        let partly = CGRect(x: 1560, y: 300, width: 400, height: 300)
        #expect(FloatingPanelFrame.reachable(partly, displays: [display]) == partly)
        #expect(FloatingPanelFrame.reachable(inside, displays: []) == inside, "no display is known: no move")
    }

    @Test func aFrameOffEachDisplayMovesTheLeastThatBringsItsBarBack() {
        let reach = FloatingPanelFrame.reach
        // Right of the display: only the left edge of the bar comes back.
        let right = FloatingPanelFrame.reachable(CGRect(x: 2000, y: 300, width: 400, height: 300), displays: [display])
        #expect(right == CGRect(x: 1600 - reach, y: 300, width: 400, height: 300))
        // Left of the display.
        let left = FloatingPanelFrame.reachable(CGRect(x: -900, y: 300, width: 400, height: 300), displays: [display])
        #expect(left == CGRect(x: reach - 400, y: 300, width: 400, height: 300))
        // Above the display: the whole bar comes under its top edge.
        let above = FloatingPanelFrame.reachable(CGRect(x: 300, y: 1100, width: 400, height: 300), displays: [display])
        #expect(above == CGRect(x: 300, y: 900, width: 400, height: 300))
        // Under the display: the bar comes above its bottom edge.
        let under = FloatingPanelFrame.reachable(CGRect(x: 300, y: -500, width: 400, height: 300), displays: [display])
        #expect(under == CGRect(x: 300, y: FloatingPanelFrame.barHeight - 300, width: 400, height: 300))
    }

    @Test func aFrameOnASecondDisplayStaysThereAndComesBackWhenThatDisplayGoes() {
        let second = CGRect(x: 1600, y: 0, width: 1600, height: 1200)
        let frame = CGRect(x: 2000, y: 300, width: 400, height: 300)
        #expect(FloatingPanelFrame.reachable(frame, displays: [display, second]) == frame)
        #expect(FloatingPanelFrame.reachable(frame, displays: [display]) == CGRect(x: 1560, y: 300, width: 400, height: 300))
        // Between 2 displays that do not touch: the nearer one takes it.
        let far = CGRect(x: 4000, y: 0, width: 1600, height: 1200)
        let between = FloatingPanelFrame.reachable(CGRect(x: 3700, y: 300, width: 200, height: 300), displays: [display, far])
        #expect(between == CGRect(x: 3840, y: 300, width: 200, height: 300))
    }

    @Test func thePlanShowsAFrameInReachAndKeepsTheFractions() {
        // The area is small and the pane is far right of it, off the one display.
        let small = CGRect(x: 1000, y: 200, width: 400, height: 400)
        let list = [LayoutFloatingPane(pane: a, frame: CGRect(x: 2, y: 0.25, width: 0.5, height: 0.5))]
        let content = Plan.Content(workspace: "one", isShown: true, isCovered: false, floating: list, hidden: [], elsewhere: [], area: small)
        let shown = Plan(contents: [content], displays: [display], scale: 1)
        #expect(shown.panels.first?.frame == CGRect(x: 1560, y: 300, width: 200, height: 200))
        let both = Plan(contents: [content], displays: [display, CGRect(x: 1600, y: 0, width: 1600, height: 1200)], scale: 1)
        #expect(both.panels.first?.frame == CGRect(x: 1800, y: 300, width: 200, height: 200), "with the second display: where the fractions say")
    }
}
