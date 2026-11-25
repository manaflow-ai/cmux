import AppKit
@testable import CmuxNextApp
import Testing

/// REOPEN-F7 (xctrace of 4 warm realistic reopens, cmux23 job 7c919613): binding the actions at launch built the
/// notifications panel's view (NotificationHandlers.bind -> NotificationsPanelController -> NotificationsPanelView.init,
/// about 13 ms of applicationDidFinishLaunching before the first window frame), a panel no reopened window shows. The
/// view is made when the panel first opens; binding makes none.
@MainActor
@Suite(.serialized) struct NotificationsPanelLazyTests {
    @Test func bindingMakesNoPanelView() {
        let services = MachineIconTests.services()
        let controller = NotificationsPanelController(context: AppActionContext(services: services))
        #expect(controller.cardView == nil, "the notifications panel's view was built before it ever opened")
        #expect(!controller.isShown)
    }
}
