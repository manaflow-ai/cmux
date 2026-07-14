import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class NotificationListControlCommandContext: ControlCommandContext {
    private(set) var resolveOnMainCallCount = 0
    var notifications: [ControlNotificationSnapshot] = []

    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        MainActor.assumeIsolated {
            resolveOnMainCallCount += 1
            return body(self)
        }
    }

    func controlNotificationList() -> [ControlNotificationSnapshot] {
        notifications
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

    @Test func notificationListPreservesLargeSnapshotOrderAndWireShape() throws {
        let context = NotificationListControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshots = (0..<10_500).reversed().map { index in
            ControlNotificationSnapshot(
                id: UUID(),
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                title: "Notification \(index)",
                subtitle: "Subtitle",
                body: "Body",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: index.isMultiple(of: 2),
                tabTitle: "Workspace"
            )
        }
        context.notifications = snapshots
        let request = ControlRequest(id: .int(1), method: "notification.list", params: [:])

        guard case .ok(.object(let payload))? = coordinator.handleSocketWorkerV2(
            request,
            context: context
        ), case .array(let notifications) = payload["notifications"],
        case .object(let first) = notifications.first,
        case .object(let last) = notifications.last else {
            Issue.record("notification.list worker handler returned an unexpected payload")
            return
        }

        #expect(context.resolveOnMainCallCount == 1)
        #expect(notifications.count == snapshots.count)
        #expect(first["id"] == .string(try #require(snapshots.first).id.uuidString))
        #expect(first["created_at"] == .string("1970-01-01T02:54:59Z"))
        #expect(first["workspace_ref"] == .string("workspace:1"))
        #expect(first["surface_ref"] == .string("surface:1"))
        #expect(last["id"] == .string(try #require(snapshots.last).id.uuidString))
        #expect(last["created_at"] == .string("1970-01-01T00:00:00Z"))
    }
}
