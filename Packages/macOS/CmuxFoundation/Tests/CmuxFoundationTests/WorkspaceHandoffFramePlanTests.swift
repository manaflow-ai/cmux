import Foundation
import Testing
@testable import CmuxFoundation

struct WorkspaceHandoffFramePlanTests {
    @Test func emptyExpectationIsCompleteImmediately() {
        let plan = WorkspaceHandoffFramePlan(workspaceId: UUID(), expectedSurfaceIds: [])
        #expect(plan.isComplete)
    }

    @Test func completesExactlyWhenEveryExpectedSurfaceRendered() {
        let ws = UUID()
        let a = UUID(), b = UUID()
        var plan = WorkspaceHandoffFramePlan(workspaceId: ws, expectedSurfaceIds: [a, b])

        let firstCompleted = plan.recordFrame(workspaceId: ws, surfaceId: a)
        #expect(!firstCompleted)
        #expect(!plan.isComplete)
        let secondCompleted = plan.recordFrame(workspaceId: ws, surfaceId: b)
        #expect(secondCompleted)
        #expect(plan.isComplete)
    }

    @Test func ignoresFramesFromOtherWorkspaces() {
        let ws = UUID()
        let a = UUID()
        var plan = WorkspaceHandoffFramePlan(workspaceId: ws, expectedSurfaceIds: [a])

        let completed = plan.recordFrame(workspaceId: UUID(), surfaceId: a)
        #expect(!completed)
        #expect(!plan.isComplete)
    }

    @Test func repeatedAndUnknownFramesAreHarmless() {
        let ws = UUID()
        let a = UUID()
        var plan = WorkspaceHandoffFramePlan(workspaceId: ws, expectedSurfaceIds: [a])

        let unknownCompleted = plan.recordFrame(workspaceId: ws, surfaceId: UUID())
        #expect(!unknownCompleted)
        let expectedCompleted = plan.recordFrame(workspaceId: ws, surfaceId: a)
        #expect(expectedCompleted)
        // A late duplicate frame does not re-fire completion.
        let duplicateCompleted = plan.recordFrame(workspaceId: ws, surfaceId: a)
        #expect(!duplicateCompleted)
    }
}
