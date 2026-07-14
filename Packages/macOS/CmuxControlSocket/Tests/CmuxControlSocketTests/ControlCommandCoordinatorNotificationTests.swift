import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class NotificationListControlCommandContext: ControlCommandContext {
    private(set) var resolveOnMainCallCount = 0

    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        MainActor.assumeIsolated {
            resolveOnMainCallCount += 1
            return body(self)
        }
    }
}

@MainActor
@Suite("ControlCommandCoordinator notification domain")
struct ControlCommandCoordinatorNotificationTests {
    @Test func notificationListWorkerHandlerUsesOneMainHop() {
        let context = NotificationListControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let request = ControlRequest(id: .int(1), method: "notification.list", params: [:])

        guard case .ok(.object(let payload))? = coordinator.handleSocketWorkerV2(
            request,
            context: context
        ), case .array(let notifications) = payload["notifications"] else {
            Issue.record("notification.list worker handler did not return its list payload")
            return
        }

        #expect(context.resolveOnMainCallCount == 1)
        #expect(notifications.isEmpty)
    }
}
