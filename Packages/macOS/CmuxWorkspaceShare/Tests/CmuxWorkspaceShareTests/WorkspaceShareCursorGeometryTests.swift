import CmuxWorkspaceShare
import Testing

@Suite
struct WorkspaceShareCursorGeometryTests {
    @Test
    func matchesAustinsSkyComputerUseCursor() {
        #expect(WorkspaceShareCursorGeometry.viewWidth == 24)
        #expect(WorkspaceShareCursorGeometry.viewHeight == 30)
        #expect(WorkspaceShareCursorGeometry.scale == 1.5)
        #expect(WorkspaceShareCursorGeometry.strokeWidth == 1.7)
        #expect(WorkspaceShareCursorGeometry.hotspotInset == 0.5)
        #expect(WorkspaceShareCursorGeometry.elements == [
            .move(x: 0.68, y: 1.83),
            .line(x: 3.63, y: 9.78),
            .quadratic(controlX: 4.67, controlY: 12.59, x: 5.3, y: 9.66),
            .line(x: 5.44, y: 9.01),
            .quadratic(controlX: 6.08, controlY: 6.08, x: 9.01, y: 5.44),
            .line(x: 9.66, y: 5.3),
            .quadratic(controlX: 12.59, controlY: 4.67, x: 9.78, y: 3.63),
            .line(x: 1.83, y: 0.68),
            .quadratic(controlX: 0, controlY: 0, x: 0.68, y: 1.83),
            .close,
        ])
    }
}
