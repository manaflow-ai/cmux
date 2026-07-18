import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeFeedControlCommandContext: ControlCommandContext {
    var jumpResult = false
    var jumpedWorkstreamID: String?

    func controlFeedJump(workstreamID: String) -> Bool {
        jumpedWorkstreamID = workstreamID
        return jumpResult
    }
}

@MainActor
@Suite("ControlCommandCoordinator Feed domain")
struct ControlCommandCoordinatorFeedTests {
    @Test func feedJumpDispatchesTheSharedFocusAction() {
        let context = FakeFeedControlCommandContext()
        context.jumpResult = true
        let coordinator = ControlCommandCoordinator(context: context)
        let request = ControlRequest(
            id: .int(1),
            method: "feed.jump",
            params: ["workstream_id": .string("opencode-session-1")]
        )

        #expect(coordinator.handle(request) == .ok(.object([
            "workstream_id": .string("opencode-session-1"),
            "matched": .bool(true),
        ])))
        #expect(context.jumpedWorkstreamID == "opencode-session-1")
    }
}
