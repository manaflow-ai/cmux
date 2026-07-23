import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct SidebarWorkspaceReorderMovePlanTests {
    private let planner = SidebarWorkspaceReorderMovePlanner()

    /// Applies steps with `NSTableView.moveRow` semantics: remove at `from`,
    /// insert at `to`.
    private func apply(_ steps: [SidebarWorkspaceReorderMoveStep], to current: [String]) -> [String] {
        var live = current
        for step in steps {
            let id = live.remove(at: step.from)
            live.insert(id, at: step.to)
        }
        return live
    }

    @Test func identityPlansNoSteps() throws {
        let ids = ["a", "b", "c"]
        let steps = try #require(planner.plan(current: ids, target: ids, movedIds: ["a"]))
        #expect(steps.isEmpty)
    }

    /// A single row dragged across the whole list is one move, not one move
    /// per displaced row.
    @Test func downwardSingleRowMoveIsOneStep() throws {
        let current = ["a", "b", "c", "d", "e"]
        let target = ["b", "c", "d", "a", "e"]
        let steps = try #require(planner.plan(current: current, target: target, movedIds: ["a"]))
        #expect(steps == [SidebarWorkspaceReorderMoveStep(from: 0, to: 3)])
        #expect(apply(steps, to: current) == target)
    }

    @Test func upwardSingleRowMoveIsOneStep() throws {
        let current = ["a", "b", "c", "d"]
        let target = ["d", "a", "b", "c"]
        let steps = try #require(planner.plan(current: current, target: target, movedIds: ["d"]))
        #expect(steps == [SidebarWorkspaceReorderMoveStep(from: 3, to: 0)])
        #expect(apply(steps, to: current) == target)
    }

    /// A group block (header plus members) moves with one step per block row.
    @Test func groupBlockMovesWithOneStepPerRow() throws {
        let current = ["h", "m1", "m2", "x", "y"]
        let target = ["x", "y", "h", "m1", "m2"]
        let steps = try #require(planner.plan(current: current, target: target, movedIds: ["h", "m1", "m2"]))
        #expect(steps.count == 3)
        #expect(apply(steps, to: current) == target)
    }

    @Test func blockMoveToFrontAndRestore() throws {
        let current = ["x", "y", "h", "m1", "m2"]
        let target = ["h", "m1", "m2", "x", "y"]
        let steps = try #require(planner.plan(current: current, target: target, movedIds: ["h", "m1", "m2"]))
        #expect(apply(steps, to: current) == target)
        let restore = try #require(planner.plan(current: target, target: current, movedIds: ["h", "m1", "m2"]))
        #expect(apply(restore, to: target) == current)
    }

    /// Every slot a single dragged row can land in replays to the target.
    @Test func singleRowMoveCoversEverySlot() throws {
        let current = (0..<12).map(String.init)
        for draggedIndex in current.indices {
            for insertionIndex in current.indices {
                var target = current
                let id = target.remove(at: draggedIndex)
                target.insert(id, at: insertionIndex)
                let steps = try #require(planner.plan(current: current, target: target, movedIds: [id]))
                #expect(apply(steps, to: current) == target)
                #expect(steps.count <= 1)
            }
        }
    }

    /// Every slot a three-row block can land in replays to the target.
    @Test func blockMoveCoversEverySlot() throws {
        let current = ["h", "m1", "m2", "a", "b", "c", "d"]
        let block = ["h", "m1", "m2"]
        let stable = ["a", "b", "c", "d"]
        for insertionOffset in 0...stable.count {
            var target = stable
            target.insert(contentsOf: block, at: insertionOffset)
            let steps = try #require(planner.plan(current: current, target: target, movedIds: block))
            #expect(apply(steps, to: current) == target)
        }
    }

    @Test func differentIdSetsRefuse() {
        #expect(planner.plan(current: ["a", "b"], target: ["a", "c"], movedIds: ["b"]) == nil)
        #expect(planner.plan(current: ["a", "b"], target: ["a"], movedIds: ["b"]) == nil)
    }

    /// A permutation that also reorders rows outside the dragged block is not
    /// a preview this planner can express; it must refuse rather than emit a
    /// partial plan.
    @Test func stableRowReorderRefuses() {
        #expect(planner.plan(
            current: ["a", "b", "c", "d"],
            target: ["b", "a", "d", "c"],
            movedIds: ["a"]
        ) == nil)
    }
}
