import Foundation
import Testing
@testable import CmuxWindowing

@Suite("SurfaceNewWorkspaceMoveResult")
struct SurfaceNewWorkspaceMoveResultTests {
    @Test("stores every identifier verbatim")
    func storesFields() {
        let sourceWindow = UUID()
        let sourceWorkspace = UUID()
        let destinationWindow = UUID()
        let destinationWorkspace = UUID()
        let surface = UUID()
        let pane = UUID()

        let result = SurfaceNewWorkspaceMoveResult(
            sourceWindowId: sourceWindow,
            sourceWorkspaceId: sourceWorkspace,
            destinationWindowId: destinationWindow,
            destinationWorkspaceId: destinationWorkspace,
            surfaceId: surface,
            paneId: pane
        )

        #expect(result.sourceWindowId == sourceWindow)
        #expect(result.sourceWorkspaceId == sourceWorkspace)
        #expect(result.destinationWindowId == destinationWindow)
        #expect(result.destinationWorkspaceId == destinationWorkspace)
        #expect(result.surfaceId == surface)
        #expect(result.paneId == pane)
    }

    @Test("allows a nil destination window and nil pane")
    func allowsNilOptionals() {
        let result = SurfaceNewWorkspaceMoveResult(
            sourceWindowId: UUID(),
            sourceWorkspaceId: UUID(),
            destinationWindowId: nil,
            destinationWorkspaceId: UUID(),
            surfaceId: UUID(),
            paneId: nil
        )

        #expect(result.destinationWindowId == nil)
        #expect(result.paneId == nil)
    }

    @Test("is equatable by every field")
    func equatable() {
        let sourceWindow = UUID()
        let sourceWorkspace = UUID()
        let destinationWorkspace = UUID()
        let surface = UUID()

        let base = SurfaceNewWorkspaceMoveResult(
            sourceWindowId: sourceWindow,
            sourceWorkspaceId: sourceWorkspace,
            destinationWindowId: nil,
            destinationWorkspaceId: destinationWorkspace,
            surfaceId: surface,
            paneId: nil
        )
        let same = SurfaceNewWorkspaceMoveResult(
            sourceWindowId: sourceWindow,
            sourceWorkspaceId: sourceWorkspace,
            destinationWindowId: nil,
            destinationWorkspaceId: destinationWorkspace,
            surfaceId: surface,
            paneId: nil
        )
        let different = SurfaceNewWorkspaceMoveResult(
            sourceWindowId: sourceWindow,
            sourceWorkspaceId: sourceWorkspace,
            destinationWindowId: UUID(),
            destinationWorkspaceId: destinationWorkspace,
            surfaceId: surface,
            paneId: nil
        )

        #expect(base == same)
        #expect(base != different)
    }
}
