import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarMultiSelectionModel")
@MainActor
struct SidebarMultiSelectionModelTests {
    private final class Recorder: @unchecked Sendable {
        // Mutated and read on MainActor only; NotificationCenter delivers
        // posts synchronously on the posting (main) thread in these tests.
        var notifications: [Notification] = []
        var tokens: [NSObjectProtocol] = []
        let center: NotificationCenter

        init(center: NotificationCenter, names: [Notification.Name]) {
            self.center = center
            for name in names {
                tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    self?.notifications.append(note)
                })
            }
        }

        deinit {
            for token in tokens { center.removeObserver(token) }
        }
    }

    @Test func selectionMutationsMatchLegacySetOperations() {
        let model = SidebarMultiSelectionModel(notificationCenter: NotificationCenter())
        let a = UUID(), b = UUID(), c = UUID()

        model.replaceSelection(with: [a, b, c])
        #expect(model.selectedWorkspaceIds == [a, b, c])
        #expect(model.contains(b))

        model.removeFromSelection(b)
        #expect(model.selectedWorkspaceIds == [a, c])

        model.subtractSelection([c, UUID()])
        #expect(model.selectedWorkspaceIds == [a])

        model.replaceSelection(with: [a, b])
        model.intersectSelection(with: [b, c])
        #expect(model.selectedWorkspaceIds == [b])
    }

    @Test func collapsePostsUnconditionallyAndMutatesOnlyOnChange() throws {
        let center = NotificationCenter()
        let model = SidebarMultiSelectionModel(notificationCenter: center)
        let recorder = Recorder(center: center, names: [SidebarMultiSelectionShouldCollapseEvent.notificationName])
        let target = UUID()

        model.collapseSelection(to: target, isKnownWorkspace: true)
        #expect(model.selectedWorkspaceIds == [target])
        #expect(recorder.notifications.count == 1)

        // Already collapsed: the selection is unchanged but the event still
        // posts, matching the legacy clearSidebarMultiSelection.
        model.collapseSelection(to: target, isKnownWorkspace: true)
        #expect(recorder.notifications.count == 2)

        let event = try #require(SidebarMultiSelectionShouldCollapseEvent(recorder.notifications[0]))
        #expect(event.focusedWorkspaceId == target)
        #expect(recorder.notifications[0].object as? SidebarMultiSelectionModel === model)

        // Unknown workspace clears the selection.
        model.collapseSelection(to: UUID(), isKnownWorkspace: false)
        #expect(model.selectedWorkspaceIds.isEmpty)
    }

    @Test func didHideEventRoundTripsLegacyUserInfoShape() throws {
        let center = NotificationCenter()
        let model = SidebarMultiSelectionModel(notificationCenter: center)
        let recorder = Recorder(center: center, names: [SidebarMultiSelectionDidHideEvent.notificationName])
        let hidden: Set<UUID> = [UUID(), UUID()]
        let focused = UUID()

        model.postDidHide(hiddenWorkspaceIds: hidden, focusedWorkspaceId: focused)
        model.postDidHide(hiddenWorkspaceIds: hidden, focusedWorkspaceId: nil)
        #expect(recorder.notifications.count == 2)

        // Wire shape: the legacy observer read Set<UUID> / UUID under the
        // legacy key strings; assert that exact shape survives.
        let first = recorder.notifications[0]
        #expect(first.userInfo?["hiddenWorkspaceIds"] as? Set<UUID> == hidden)
        #expect(first.userInfo?["focusedWorkspaceId"] as? UUID == focused)
        let firstEvent = try #require(SidebarMultiSelectionDidHideEvent(first))
        #expect(firstEvent.hiddenWorkspaceIds == hidden)
        #expect(firstEvent.focusedWorkspaceId == focused)

        // focusedWorkspaceId key absent (not NSNull) when focus did not move.
        let second = recorder.notifications[1]
        #expect(second.userInfo?["focusedWorkspaceId"] == nil)
        let secondEvent = try #require(SidebarMultiSelectionDidHideEvent(second))
        #expect(secondEvent.focusedWorkspaceId == nil)
    }

    @Test func eventDecodeRejectsForeignNotifications() {
        let note = Notification(name: Notification.Name("cmux.unrelated"), object: nil, userInfo: nil)
        #expect(SidebarMultiSelectionDidHideEvent(note) == nil)
        #expect(SidebarMultiSelectionShouldCollapseEvent(note) == nil)

        let missingPayload = Notification(
            name: SidebarMultiSelectionShouldCollapseEvent.notificationName,
            object: nil,
            userInfo: [:]
        )
        #expect(SidebarMultiSelectionShouldCollapseEvent(missingPayload) == nil)
    }
}
