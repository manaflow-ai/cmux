import Foundation
import Testing
@testable import CmuxNotifications

@Suite(.serialized)
@MainActor
struct FocusedNotificationMarkerTests {
    /// Records every notification, workspace, and exact Dock target exclusion
    /// the marker asks to jump for, and returns a scriptable opened id.
    @MainActor
    final class JumpSpy {
        var openedId: UUID?
        private(set) var calls: [(UUID?, UUID?, WindowDockUnreadTarget?)] = []

        func jump(
            _ excludedNotificationId: UUID?,
            _ excludedWorkspaceId: UUID?,
            _ excludedWindowDockTarget: WindowDockUnreadTarget?
        ) -> UUID? {
            calls.append((
                excludedNotificationId,
                excludedWorkspaceId,
                excludedWindowDockTarget
            ))
            return openedId
        }
    }

    private func makeMarker(
        resolver: FakeFocusedResolving,
        jump: JumpSpy = JumpSpy()
    ) -> (FocusedNotificationMarker, JumpSpy) {
        let marker = FocusedNotificationMarker(
            resolver: resolver,
            jumpToLatestUnread: { jump.jump($0, $1, $2) }
        )
        return (marker, jump)
    }

    // MARK: toggle entry gate

    @Test("toggle is a no-op when no store is present")
    func toggleNoStore() {
        let resolver = FakeFocusedResolving()
        resolver.hasNotificationStore = false
        resolver.focusedTargetValue = .workspace(tabId: UUID(), surfaceId: UUID())
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread() == false)
        #expect(resolver.mutations.isEmpty)
    }

    @Test("toggle is a no-op when nothing is focused")
    func toggleNoTarget() {
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = nil
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread() == false)
        #expect(resolver.mutations.isEmpty)
    }

    @Test("toggle mutates only the exact focused window Dock surface")
    func toggleWindowDockSurface() {
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .windowDock(target)
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.unreadWindowDockTargets == [target])
        #expect(resolver.mutations == [
            "markWindowDockSurfaceUnread(\(short(target.surfaceId)))",
        ])

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.unreadWindowDockTargets.isEmpty)
        #expect(resolver.mutations == [
            "markWindowDockSurfaceUnread(\(short(target.surfaceId)))",
            "clearWindowDockSurfaceUnread(\(short(target.surfaceId)))",
        ])
    }

    // MARK: toggle, panel path

    @Test("toggle marks the workspace read when it shows a visible indicator")
    func togglePanelVisibleIndicatorMarksRead() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // Workspace-level visible indicator → first branch wins.
        resolver.visibleIndicatorSet = [.init(tabId: tab, surfaceId: nil)]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkRead(\(short(tab)))"])
    }

    @Test("toggle marks an unread panel read and clears workspace manual unread when representative")
    func togglePanelUnreadClearsManual() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // Manual unread on the representative panel → mark read + clear manual.
        resolver.storeManualUnreadTabs = [tab]
        resolver.panelIsRepresentativeSet = [panel]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["markPanelRead(\(short(surface)))", "storeClearManualUnread(\(short(tab)))"])
    }

    @Test("toggle marks a clean panel unread")
    func togglePanelMarksUnread() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // Nothing unread anywhere → toggle ON.
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["markPanelUnread(\(short(surface)))"])
    }

    // MARK: toggle, workspace (no panel) path

    @Test("toggle without a panel marks the unread workspace read")
    func toggleWorkspaceReadWhenUnread() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        // No surface → no panel resolution → workspace branch.
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: nil)
        resolver.workspaceUnreadTabs = [tab]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkRead(\(short(tab)))"])
    }

    @Test("toggle without a panel marks the read workspace unread")
    func toggleWorkspaceUnreadWhenRead() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: nil)
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkUnread(\(short(tab)))"])
    }

    // MARK: markOldest + jump

    @Test("mark-oldest marks the focused Dock surface without excluding sibling surfaces")
    func markOldestMarksWindowDockSurfaceWithoutExcludingOwner() {
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .windowDock(target)
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.unreadWindowDockTargets == [target])
        #expect(resolver.mutations == [
            "markWindowDockSurfaceUnread(\(short(target.surfaceId)))",
        ])
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.0 == nil)
        #expect(spy.calls.first?.1 == nil)
        #expect(spy.calls.first?.2 == target)
    }

    @Test("mark-oldest excludes both forms of unread on the focused Dock surface")
    func markOldestDefersWindowDockNotificationAndExactUnreadTarget() {
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let notificationID = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .windowDock(target)
        resolver.unreadWindowDockTargets = [target]
        resolver.oldestUnreadIdByWindowDockTarget[target] = notificationID
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.0 == notificationID)
        #expect(spy.calls.first?.1 == nil)
        #expect(spy.calls.first?.2 == target)
    }

    @Test("mark-oldest does not defer a notification from a sibling Dock surface")
    func markOldestDoesNotDeferSiblingWindowDockNotification() {
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let siblingNotificationID = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .windowDock(target)
        resolver.oldestUnreadIdByTab[target.windowId] = siblingNotificationID
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.unreadWindowDockTargets == [target])
        #expect(resolver.mutations == [
            "markWindowDockSurfaceUnread(\(short(target.surfaceId)))",
        ])
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.0 == nil)
        #expect(spy.calls.first?.1 == nil)
        #expect(spy.calls.first?.2 == target)
    }

    @Test("mark-oldest defers to a notification id, then jumps excluding it")
    func markOldestDefersToNotification() {
        let tab = UUID(), surface = UUID(), deferredNotif = UUID(), opened = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.oldestUnreadIdByTab[tab] = deferredNotif
        let jump = JumpSpy(); jump.openedId = opened
        let (marker, spy) = makeMarker(resolver: resolver, jump: jump)

        let result = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(result == opened)
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.0 == deferredNotif) // excluded notification id
        #expect(spy.calls.first?.1 == nil)            // not excluding a workspace
        // No panel/workspace mutation happened: the notification-deferral path returns early.
        #expect(resolver.mutations.isEmpty)
    }

    @Test("mark-oldest with no deferrable notification marks the clean panel unread, then jumps excluding the workspace")
    func markOldestMarksPanelThenJumpsExcludingWorkspace() {
        let tab = UUID(), surface = UUID(), opened = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // No deferrable notification and a clean panel → mark panel unread.
        let jump = JumpSpy(); jump.openedId = opened
        let (marker, spy) = makeMarker(resolver: resolver, jump: jump)

        let result = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(result == opened)
        #expect(resolver.mutations == ["markPanelUnread(\(short(surface)))"])
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.0 == nil)
        #expect(spy.calls.first?.1 == tab) // excluding the marked workspace
    }

    @Test("mark-oldest does NOT re-mark an already-unread panel, but still jumps")
    func markOldestSkipsAlreadyUnreadPanel() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        resolver.panelIsManualUnreadSet = [panel] // already unread → no mark
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.first?.1 == tab)
    }

    @Test("mark-oldest without a panel marks a read workspace unread, then jumps")
    func markOldestMarksWorkspaceUnread() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: nil)
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations == ["storeMarkUnread(\(short(tab)))"])
        #expect(spy.calls.first?.1 == tab)
    }

    @Test("mark-oldest is a no-op when no store is present")
    func markOldestNoStore() {
        let resolver = FakeFocusedResolving()
        resolver.hasNotificationStore = false
        resolver.focusedTargetValue = .workspace(tabId: UUID(), surfaceId: nil)
        let (marker, spy) = makeMarker(resolver: resolver)

        #expect(marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread() == nil)
        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.isEmpty)
    }

    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
}
