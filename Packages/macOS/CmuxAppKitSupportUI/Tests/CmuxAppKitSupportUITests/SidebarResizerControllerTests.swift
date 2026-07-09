import AppKit
import Testing
import CmuxSidebar
@testable import CmuxAppKitSupportUI

/// Behavioral tests for ``SidebarResizerController``.
///
/// The cursor/monitor/stabilizer paths drive `NSCursor`, `NSEvent`, and
/// `CGEventSource`, which require a live window-server session and are exercised
/// by app-level dogfood rather than here. These tests pin the parts that are
/// deterministic without an AppKit session: the drag-flag lifecycle and the
/// handle/band value types.
@MainActor
@Suite struct SidebarResizerControllerTests {
    private func makeController() -> SidebarResizerController {
        SidebarResizerController(
            bandPolicy: SidebarResizerBandPolicy(sidebarSideHitWidth: 6, contentSideHitWidth: 4),
            fixedSidebarResizeCursor: .arrow,
            clock: ContinuousClock()
        )
    }

    @Test func dragLifecycleTogglesFlag() {
        let controller = makeController()
        #expect(controller.isResizerDragging == false)
        controller.beginDrag()
        #expect(controller.isResizerDragging == true)
        controller.endDrag()
        #expect(controller.isResizerDragging == false)
    }

    @Test func dragStartWidthsRoundTrip() {
        let controller = makeController()
        #expect(controller.sidebarDragStartWidth == nil)
        #expect(controller.fileExplorerDragStartWidth == nil)
        controller.sidebarDragStartWidth = 280
        controller.fileExplorerDragStartWidth = 240
        #expect(controller.sidebarDragStartWidth == 280)
        #expect(controller.fileExplorerDragStartWidth == 240)
        controller.sidebarDragStartWidth = nil
        #expect(controller.sidebarDragStartWidth == nil)
    }

    @Test func bandInactiveWhenNoDividersVisible() {
        let controller = makeController()
        controller.updateBandState(
            inputs: SidebarResizerBandInputs(
                window: nil,
                leftDividerVisible: false,
                leftDividerX: 0,
                rightDividerVisible: false,
                rightSidebarWidth: 0
            )
        )
        #expect(controller.isResizerBandActive == false)
    }

    @Test func handleSetTracksDistinctDividers() {
        var handles: Set<SidebarResizerHandle> = []
        handles.insert(.divider)
        handles.insert(.explorerDivider)
        #expect(handles.count == 2)
        handles.remove(.divider)
        #expect(handles == [.explorerDivider])
    }
}
