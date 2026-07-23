import Foundation
import Testing
@testable import CmuxNotifications

@Suite(.serialized)
@MainActor
struct FocusedNotificationMarkerTests {
    /// Records every `(excludedNotificationId, excludedWorkspaceId)` the marker
    /// asks to jump for, and returns a scriptable opened id.
    @MainActor
    final class JumpSpy {
        var openedId: UUID?
        var didOpen = false
        private(set) var calls: [(UUID?, UUID?)] = []

        func jump(_ excludedNotificationId: UUID?, _ excludedWorkspaceId: UUID?) -> UUID? {
            calls.append((excludedNotificationId, excludedWorkspaceId))
            return openedId
        }
    }

    private func makeMarker(
        resolver: FakeFocusedResolving,
        jump: JumpSpy = JumpSpy()
    ) -> (FocusedNotificationMarker, JumpSpy) {
        let marker = FocusedNotificationMarker(
            resolver: resolver,
            jumpToLatestUnread: { jump.jump($0, $1) },
            jumpToLatestUnreadWithOutcome: { excludedNotificationId, excludedWorkspaceId in
                let openedId = jump.jump(excludedNotificationId, excludedWorkspaceId)
                return (openedId, openedId != nil || jump.didOpen)
            }
        )
        return (marker, jump)
    }

    // MARK: toggle entry gate

    @Test("toggle is a no-op when no store is present")
    func toggleNoStore() {
        let resolver = FakeFocusedResolving()
        resolver.hasNotificationStore = false
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: UUID(), surfaceId: UUID())
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

    // MARK: toggle, explicit target

    @Test("explicit toggle uses the captured panel instead of current focus")
    func toggleExplicitPanelIgnoresFocusedTarget() {
        let targetTab = UUID(), targetPanelId = UUID()
        let focusedTab = UUID(), focusedPanelId = UUID()
        let targetPanel = FocusedPanel(tabId: targetTab, panelId: targetPanelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [targetTab, focusedTab]
        resolver.focusedTargetValue = FocusedNotificationTarget(
            tabId: focusedTab,
            surfaceId: focusedPanelId
        )
        resolver.panelByTabSurface[.init(tabId: targetTab, surfaceId: targetPanelId)] = targetPanel
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.toggleNotificationUnread(workspaceId: targetTab, panelId: targetPanelId) == .completed
        )
        #expect(resolver.mutations == ["markPanelUnread(\(short(targetPanelId)))"])
    }

    @Test("explicit workspace toggle uses the captured workspace")
    func toggleExplicitWorkspace() {
        let targetTab = UUID(), focusedTab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [targetTab, focusedTab]
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: focusedTab, surfaceId: nil)
        resolver.workspaceUnreadTabs = [targetTab]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleNotificationUnread(workspaceId: targetTab, panelId: nil) == .completed)
        #expect(resolver.mutations == ["storeMarkRead(\(short(targetTab)))"])
    }

    @Test("explicit toggle fails closed when the captured workspace is stale")
    func toggleExplicitStaleWorkspace() {
        let resolver = FakeFocusedResolving()
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleNotificationUnread(workspaceId: UUID(), panelId: nil) == .targetUnavailable)
        #expect(resolver.mutations.isEmpty)
    }

    @Test("explicit toggle fails closed when the captured panel is stale")
    func toggleExplicitStalePanel() {
        let tab = UUID(), stalePanelId = UUID()
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.toggleNotificationUnread(workspaceId: tab, panelId: stalePanelId) == .targetUnavailable
        )
        #expect(resolver.mutations.isEmpty)
    }

    @Test("explicit unread setter marks a clean captured panel unread")
    func setExplicitPanelUnread() {
        let tab = UUID(), panelId = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: panelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: panelId)] = panel
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.setNotificationUnread(
                workspaceId: tab,
                panelId: panelId,
                unread: true
            ) == .completed
        )
        #expect(resolver.mutations == ["markPanelUnread(\(short(panelId)))"])
    }

    @Test("explicit unread setter is idempotent when the captured panel already matches")
    func setExplicitPanelUnreadIdempotently() {
        let tab = UUID(), panelId = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: panelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: panelId)] = panel
        resolver.panelIsManualUnreadSet = [panel]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.setNotificationUnread(
                workspaceId: tab,
                panelId: panelId,
                unread: true
            ) == .completed
        )
        #expect(resolver.mutations.isEmpty)
    }

    @Test("explicit unread setter marks the captured unread panel read")
    func setExplicitPanelRead() {
        let tab = UUID(), panelId = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: panelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: panelId)] = panel
        resolver.panelIsManualUnreadSet = [panel]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.setNotificationUnread(
                workspaceId: tab,
                panelId: panelId,
                unread: false
            ) == .completed
        )
        #expect(resolver.mutations == ["markPanelRead(\(short(panelId)))"])
    }

    @Test("explicit unread setter clears coexisting workspace and panel unread sources")
    func setExplicitPanelReadClearsAllSources() {
        let tab = UUID(), panelId = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: panelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: panelId)] = panel
        resolver.visibleIndicatorSet = [
            .init(tabId: tab, surfaceId: nil),
            .init(tabId: tab, surfaceId: panelId),
        ]
        resolver.storeManualUnreadTabs = [tab]
        resolver.panelIsRepresentativeSet = [panel]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.setNotificationUnread(
                workspaceId: tab,
                panelId: panelId,
                unread: false
            ) == .completed
        )
        #expect(resolver.mutations == [
            "storeMarkRead(\(short(tab)))",
            "markPanelRead(\(short(panelId)))",
            "storeClearManualUnread(\(short(tab)))",
        ])
    }

    @Test("explicit unread setter fails closed for a stale panel")
    func setExplicitStalePanel() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(
            marker.setNotificationUnread(
                workspaceId: tab,
                panelId: UUID(),
                unread: true
            ) == .targetUnavailable
        )
        #expect(resolver.mutations.isEmpty)
    }

    @Test("focused toggle keeps its workspace fallback when surface resolution fails")
    func toggleFocusedUnresolvedSurfacePreservesWorkspaceFallback() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: UUID())
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkUnread(\(short(tab)))"])
    }

    // MARK: toggle, panel path

    @Test("toggle marks the workspace read when it shows a visible indicator")
    func togglePanelVisibleIndicatorMarksRead() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: surface)
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
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: surface)
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
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: surface)
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
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: nil)
        resolver.workspaceUnreadTabs = [tab]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkRead(\(short(tab)))"])
    }

    @Test("toggle without a panel marks the read workspace unread")
    func toggleWorkspaceUnreadWhenRead() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: nil)
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkUnread(\(short(tab)))"])
    }

    // MARK: markOldest + jump

    @Test("mark-oldest defers to a notification id, then jumps excluding it")
    func markOldestDefersToNotification() {
        let tab = UUID(), surface = UUID(), deferredNotif = UUID(), opened = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: surface)
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
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: surface)
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
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: surface)
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
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: tab, surfaceId: nil)
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations == ["storeMarkUnread(\(short(tab)))"])
        #expect(spy.calls.first?.1 == tab)
    }

    @Test("explicit mark-oldest uses the captured panel instead of current focus")
    func markOldestExplicitPanelIgnoresFocusedTarget() {
        let targetTab = UUID(), targetPanelId = UUID(), deferredNotificationId = UUID()
        let focusedTab = UUID(), focusedPanelId = UUID()
        let targetPanel = FocusedPanel(tabId: targetTab, panelId: targetPanelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [targetTab, focusedTab]
        resolver.focusedTargetValue = FocusedNotificationTarget(
            tabId: focusedTab,
            surfaceId: focusedPanelId
        )
        resolver.panelByTabSurface[.init(tabId: targetTab, surfaceId: targetPanelId)] = targetPanel
        resolver.oldestUnreadIdByTab[targetTab] = deferredNotificationId
        let (marker, spy) = makeMarker(resolver: resolver)

        let outcome = marker.markNotificationAsOldestUnreadAndJumpToNextLatestUnread(
            workspaceId: targetTab,
            panelId: targetPanelId
        )

        #expect(outcome == .completed)
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.0 == deferredNotificationId)
        #expect(spy.calls.first?.1 == nil)
        #expect(resolver.mutations.isEmpty)
    }

    @Test("explicit mark-oldest fails closed when the captured panel is stale")
    func markOldestExplicitStalePanel() {
        let tab = UUID(), stalePanelId = UUID()
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.oldestUnreadIdByTab[tab] = UUID()
        let (marker, spy) = makeMarker(resolver: resolver)

        #expect(
            marker.markNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                workspaceId: tab,
                panelId: stalePanelId
            ) == .targetUnavailable
        )
        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.isEmpty)
    }

    @Test("explicit mark-oldest reports not applicable when it cannot mark or jump")
    func markOldestExplicitNotApplicable() {
        let tab = UUID(), panelId = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: panelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: panelId)] = panel
        resolver.panelIsManualUnreadSet = [panel]
        let (marker, spy) = makeMarker(resolver: resolver)

        let outcome = marker.markNotificationAsOldestUnreadAndJumpToNextLatestUnread(
            workspaceId: tab,
            panelId: panelId
        )

        #expect(outcome == .notApplicable)
        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.count == 1)
    }

    @Test("explicit mark-oldest reports completion for a workspace fallback jump")
    func markOldestExplicitWorkspaceFallbackCompleted() {
        let tab = UUID(), panelId = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: panelId)
        let resolver = FakeFocusedResolving()
        resolver.existingWorkspaceIds = [tab]
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: panelId)] = panel
        resolver.panelIsManualUnreadSet = [panel]
        let jump = JumpSpy()
        jump.didOpen = true
        let (marker, spy) = makeMarker(resolver: resolver, jump: jump)

        let outcome = marker.markNotificationAsOldestUnreadAndJumpToNextLatestUnread(
            workspaceId: tab,
            panelId: panelId
        )

        #expect(outcome == .completed)
        #expect(spy.openedId == nil)
        #expect(spy.calls.count == 1)
    }

    @Test("mark-oldest is a no-op when no store is present")
    func markOldestNoStore() {
        let resolver = FakeFocusedResolving()
        resolver.hasNotificationStore = false
        resolver.focusedTargetValue = FocusedNotificationTarget(tabId: UUID(), surfaceId: nil)
        let (marker, spy) = makeMarker(resolver: resolver)

        #expect(marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread() == nil)
        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.isEmpty)
    }

    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
}
