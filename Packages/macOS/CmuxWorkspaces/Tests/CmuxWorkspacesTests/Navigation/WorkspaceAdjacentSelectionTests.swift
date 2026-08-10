import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Workspace adjacent selection")
struct WorkspaceAdjacentSelectionTests {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let hidden = UUID()

    @Test func stepsForwardAndWrapsAtTheEnd() {
        let stops = [a, b, c]
        #expect(WorkspaceAdjacentSelection.target(stops: stops, current: a, step: 1) == b)
        #expect(WorkspaceAdjacentSelection.target(stops: stops, current: c, step: 1) == a)
    }

    @Test func stepsBackwardAndWrapsAtTheStart() {
        let stops = [a, b, c]
        #expect(WorkspaceAdjacentSelection.target(stops: stops, current: b, step: -1) == a)
        #expect(WorkspaceAdjacentSelection.target(stops: stops, current: a, step: -1) == c)
    }

    @Test func hiddenCurrentStepsFromItsFallbackStop() {
        let stops = [a, b, c]
        #expect(WorkspaceAdjacentSelection.target(
            stops: stops, current: hidden, fallbackStop: b, step: 1
        ) == c)
        #expect(WorkspaceAdjacentSelection.target(
            stops: stops, current: hidden, fallbackStop: b, step: -1
        ) == a)
    }

    @Test func singleStopReturnsItself() {
        #expect(WorkspaceAdjacentSelection.target(stops: [a], current: a, step: 1) == a)
    }

    @Test func unresolvableCurrentReturnsNil() {
        #expect(WorkspaceAdjacentSelection.target(stops: [a], current: hidden, step: 1) == nil)
        #expect(WorkspaceAdjacentSelection.target(stops: [], current: a, step: 1) == nil)
    }
}
