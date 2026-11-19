@testable import CmuxNextMacScreen
import CmuxNextRemoteView
import Testing

/// The access button when several viewers watch one host: "View only: <name> has control".
@MainActor @Suite struct MacScreenFloorTests {
    @Test func anotherViewerInControlIsNamed() {
        let title = MacScreenToolbarView.accessTitle(viewOnly: false, floor: RemoteFloor(control: false, holder: "Ann's Mac"))
        #expect(title.contains("Ann's Mac"))
        #expect(title != MacScreenToolbarView.accessTitle(viewOnly: false, floor: nil))
    }

    @Test func holdingControlOrNoFloorShowsTheScope() {
        let full = MacScreenToolbarView.accessTitle(viewOnly: false, floor: nil)
        #expect(MacScreenToolbarView.accessTitle(viewOnly: false, floor: RemoteFloor(control: true)) == full)
        let view = MacScreenToolbarView.accessTitle(viewOnly: true, floor: nil)
        // A View Only session stays View Only whoever holds control.
        #expect(MacScreenToolbarView.accessTitle(viewOnly: true, floor: RemoteFloor(control: false, holder: "Ann")) == view)
        #expect(MacScreenToolbarView.accessTitle(viewOnly: false, floor: RemoteFloor(control: false)) == view)
    }
}
