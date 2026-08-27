import AppKit
import SwiftUI
import Testing
@testable import CmuxUpdaterUI

@MainActor
@Suite("Update pill popover resize", .serialized)
struct UpdatePillPopoverResizeTests {
    @Test("Visible content refresh does not resize the popover synchronously")
    func visibleContentRefreshDoesNotResizeSynchronously() async {
        var isPresented = true
        let popover = VisibleRecordingPopover()
        popover.animates = true
        let coordinator = UpdatePillPopoverAnchor.Coordinator(
            isPresented: Binding(
                get: { isPresented },
                set: { isPresented = $0 }
            )
        )
        coordinator.popover = popover

        coordinator.updateRootView(popoverContent(width: 180, height: 80))
        await Task.yield()
        #expect(popover.isShown)
        #expect(popover.animates)
        popover.resetRecordedAssignments()

        coordinator.updateRootView(popoverContent(width: 360, height: 240))

        #expect(
            popover.assignedSizes.isEmpty,
            "A visible representable update must return before changing NSPopover.contentSize"
        )
        await Task.yield()
        #expect(popover.assignedSizes == [NSSize(width: 360, height: 240)])
    }

    private func popoverContent(width: CGFloat, height: CGFloat) -> AnyView {
        AnyView(
            Color.clear
                .frame(width: width, height: height)
                .fixedSize()
        )
    }
}

@MainActor
/// Supplies shown-popover state without requiring a WindowServer and records the real AppKit mutation boundary.
private final class VisibleRecordingPopover: NSPopover {
    private var storedContentSize = NSSize.zero
    private(set) var assignedSizes: [NSSize] = []

    override var isShown: Bool { true }

    override var contentSize: NSSize {
        get { storedContentSize }
        set {
            storedContentSize = newValue
            assignedSizes.append(newValue)
        }
    }

    func resetRecordedAssignments() {
        assignedSizes.removeAll()
    }
}
