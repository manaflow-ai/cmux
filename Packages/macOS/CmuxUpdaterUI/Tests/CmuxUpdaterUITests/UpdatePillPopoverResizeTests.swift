import AppKit
import CmuxUpdater
import Testing
@testable import CmuxUpdaterUI

@MainActor
@Suite("Update popover native sizing", .serialized)
struct UpdatePillPopoverResizeTests {
    @Test("A state transition recomputes native popover content size")
    func stateTransitionRecomputesContentSize() async {
        let model = UpdateStateModel()
        model.setState(.checking(.init(cancel: {})))
        let controller = UpdatePopoverViewController(
            model: model,
            actions: TestUpdateActionsHost()
        )
        let checkingSize = controller.preferredContentSize

        model.setState(.error(.init(
            error: NSError(domain: "test.update", code: 1),
            retry: {},
            dismiss: {},
            technicalDetails: String(repeating: "Details ", count: 20),
            feedURLString: nil
        )))
        await Task.yield()

        #expect(checkingSize.width == 300)
        #expect(controller.preferredContentSize.width == 300)
        #expect(controller.preferredContentSize.height > checkingSize.height)
    }
}

@MainActor
private final class TestUpdateActionsHost: UpdateActionsHost {
    let updateLogPath = "/tmp/cmux-update-test.log"

    func checkForUpdatesInCustomUI() {}
    func attemptUpdate() {}
}
