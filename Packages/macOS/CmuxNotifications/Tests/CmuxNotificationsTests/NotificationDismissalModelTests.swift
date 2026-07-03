import Foundation
import Testing
@testable import CmuxNotifications

/// Recording fake host: scriptable state reads plus an ordered log of every
/// mutation, so tests assert both the dismissal decision and the exact
/// side-effect sequence the legacy flow produced.
@MainActor
private final class FakeHost: NotificationDismissalHosting {
    var selectedWorkspaceId: UUID?
    var isAppActive = true
    var hasNotificationStore = true
    var focusedPanelIds: [UUID: UUID] = [:]
    var focusedSurfaceIds: [UUID: UUID] = [:]
    var suppressOnlyFocusedSurface = false
    var panelIdsBySurface: [UUID: UUID] = [:]
    var manualPanelUnread: Set<UUID> = []
    var restoredPanelUnread: Set<UUID> = []
    var manualWorkspaceUnread: Set<UUID> = []
    var restoredWorkspaceUnread: Set<UUID> = []
    var unreadNotificationSurfaces: Set<UUID> = []
    var workspaceWideUnread: Set<UUID> = []
    var visibleIndicatorSurfaces: Set<UUID> = []

    var log: [String] = []

    private func short(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(4)) } ?? "nil"
    }

    func focusedPanelId(in workspaceId: UUID) -> UUID? {
        focusedPanelIds[workspaceId]
    }

    func focusedSurfaceId(in workspaceId: UUID) -> UUID? {
        focusedSurfaceIds[workspaceId]
    }

    func panelId(forSurfaceOrPanelId surfaceId: UUID, in workspaceId: UUID) -> UUID? {
        panelIdsBySurface[surfaceId] ?? surfaceId
    }

    func workspaceHasManualPanelUnread(workspaceId: UUID, panelId: UUID) -> Bool {
        manualPanelUnread.contains(panelId)
    }

    func workspaceHasRestoredPanelUnread(workspaceId: UUID, panelId: UUID) -> Bool {
        restoredPanelUnread.contains(panelId)
    }

    func storeHasManualUnread(workspaceId: UUID) -> Bool {
        manualWorkspaceUnread.contains(workspaceId)
    }

    func storeHasRestoredUnreadIndicator(workspaceId: UUID) -> Bool {
        restoredWorkspaceUnread.contains(workspaceId)
    }

    func storeHasUnreadNotification(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        guard let surfaceId else { return workspaceWideUnread.contains(workspaceId) }
        return unreadNotificationSurfaces.contains(surfaceId)
    }

    func storeHasVisibleNotificationIndicator(workspaceId: UUID, surfaceId: UUID?) -> Bool {
        guard let surfaceId else { return false }
        return visibleIndicatorSurfaces.contains(surfaceId)
    }

    func storeHasDismissibleActivity(workspaceId: UUID) -> Bool {
        workspaceWideUnread.contains(workspaceId) ||
            !unreadNotificationSurfaces.isEmpty ||
            !visibleIndicatorSurfaces.isEmpty ||
            !manualPanelUnread.isEmpty ||
            !restoredPanelUnread.isEmpty ||
            manualWorkspaceUnread.contains(workspaceId) ||
            restoredWorkspaceUnread.contains(workspaceId)
    }

    func storeMarkRead(workspaceId: UUID, surfaceId: UUID?) {
        log.append("markRead:\(short(surfaceId))")
    }

    func storeClearManualUnread(workspaceId: UUID) -> Bool {
        log.append("storeClearManualUnread")
        return manualWorkspaceUnread.contains(workspaceId)
    }

    func storeClearRestoredUnreadIndicator(workspaceId: UUID) -> Bool {
        log.append("storeClearRestoredUnread")
        return restoredWorkspaceUnread.contains(workspaceId)
    }

    func storeClearFocusedReadIndicator(workspaceId: UUID, surfaceId: UUID?) {
        log.append("clearFocusedRead:\(short(surfaceId))")
    }

    func workspaceClearManualUnread(workspaceId: UUID, panelId: UUID) {
        log.append("panelClearManualUnread")
    }

    func workspaceClearRestoredUnreadIndicator(workspaceId: UUID, panelId: UUID) {
        log.append("panelClearRestoredUnread")
    }

    func workspaceTriggerNotificationDismissFlash(workspaceId: UUID, panelId: UUID) {
        log.append("notificationFlash")
    }

    func workspaceTriggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        log.append("unreadIndicatorFlash")
    }
}

@MainActor
private func makeModel() -> (NotificationDismissalModel, FakeHost, workspaceId: UUID, panelId: UUID) {
    let model = NotificationDismissalModel()
    let host = FakeHost()
    let workspaceId = UUID()
    let panelId = UUID()
    host.selectedWorkspaceId = workspaceId
    host.focusedPanelIds[workspaceId] = panelId
    // Production aliases the focused surface to the focused panel
    // (`TabManager.focusedSurfaceId(for:)` -> `focusedPanelId`).
    host.focusedSurfaceIds[workspaceId] = panelId
    model.attach(host: host)
    return (model, host, workspaceId, panelId)
}

@Suite("NotificationDismissalModel")
@MainActor
struct NotificationDismissalModelTests {
    @Test func dismissRequiresSelectedWorkspace() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.unreadNotificationSurfaces = [panelId]
        host.selectedWorkspaceId = UUID()
        #expect(!model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: panelId))
        #expect(host.log.isEmpty)
    }

    @Test func activeFocusContextRequiresActiveApp() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.unreadNotificationSurfaces = [panelId]
        host.isAppActive = false

        // activeFocus requires an active app: suppressed.
        model.dismissPanelNotificationOnFocus(
            workspaceId: workspaceId, panelId: panelId, explicitFocusIntent: false
        )
        #expect(host.log.isEmpty)

        // directInteraction does not: proceeds while inactive.
        #expect(model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: panelId))
        #expect(host.log.contains("markRead:\(panelId.uuidString.prefix(4))"))
    }

    @Test func missingNotificationStoreShortCircuits() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.unreadNotificationSurfaces = [panelId]
        host.hasNotificationStore = false
        #expect(!model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: panelId))
        #expect(host.log.isEmpty)
    }

    @Test func unreadNotificationDismissalMarksReadAndFlashes() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.unreadNotificationSurfaces = [panelId]
        #expect(model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: panelId))
        let prefix = String(panelId.uuidString.prefix(4))
        #expect(host.log == ["markRead:\(prefix)", "clearFocusedRead:\(prefix)", "notificationFlash"])
    }

    @Test func surfaceAliasMarksBothSurfaceAndPanel() {
        let (model, host, workspaceId, panelId) = makeModel()
        let surfaceId = UUID()
        host.panelIdsBySurface[surfaceId] = panelId
        host.unreadNotificationSurfaces = [surfaceId]
        #expect(model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: surfaceId))
        let surfacePrefix = String(surfaceId.uuidString.prefix(4))
        let panelPrefix = String(panelId.uuidString.prefix(4))
        // Legacy order: the raw surface id first, then the resolved panel id.
        #expect(host.log == [
            "markRead:\(surfacePrefix)", "markRead:\(panelPrefix)",
            "clearFocusedRead:\(surfacePrefix)", "clearFocusedRead:\(panelPrefix)",
            "notificationFlash",
        ])
    }

    @Test func manualUnreadOnlyClearsOnTerminalInteraction() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.manualPanelUnread = [panelId]
        host.manualWorkspaceUnread = [workspaceId]

        // Direct interaction may not clear a manually-set unread indicator.
        #expect(!model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: panelId))
        #expect(host.log.isEmpty)

        // Terminal interaction clears it and triggers the indicator flash.
        #expect(model.dismissNotificationOnTerminalInteraction(workspaceId: workspaceId, surfaceId: panelId))
        let prefix = String(panelId.uuidString.prefix(4))
        #expect(host.log == [
            "panelClearManualUnread", "storeClearManualUnread",
            "clearFocusedRead:\(prefix)", "unreadIndicatorFlash",
        ])
    }

    @Test func restoredUnreadNotClearedByPlainActiveFocus() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.restoredPanelUnread = [panelId]
        host.restoredWorkspaceUnread = [workspaceId]

        // Plain active focus (restore/programmatic) must not clear it.
        model.dismissPanelNotificationOnFocus(
            workspaceId: workspaceId, panelId: panelId, explicitFocusIntent: false
        )
        #expect(host.log.isEmpty)

        // Explicit workspace resume does.
        model.dismissFocusedPanelNotificationIfActive(
            workspaceId: workspaceId, context: .explicitWorkspaceResume
        )
        let prefix = String(panelId.uuidString.prefix(4))
        #expect(host.log == [
            "panelClearRestoredUnread", "storeClearRestoredUnread",
            "clearFocusedRead:\(prefix)", "unreadIndicatorFlash",
        ])
    }

    @Test func suppressFocusFlashLatchConsumesOnFirstFocusDismiss() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.unreadNotificationSurfaces = [panelId]

        model.setSuppressesFocusFlash(true)
        #expect(model.suppressesFocusFlash)

        // First call consumes the latch and dismisses nothing.
        model.dismissFocusedPanelNotificationIfActive(workspaceId: workspaceId, context: .activeFocus)
        #expect(host.log.isEmpty)
        #expect(!model.suppressesFocusFlash)

        // Second call proceeds normally.
        model.dismissFocusedPanelNotificationIfActive(workspaceId: workspaceId, context: .activeFocus)
        #expect(host.log.contains("notificationFlash"))
    }

    @Test func pendingSelectionContextTakeClearsIt() {
        let (model, _, _, _) = makeModel()
        #expect(model.takePendingSelectionContext() == nil)

        model.setPendingSelectionContext(.explicitWorkspaceResume)
        #expect(model.takePendingSelectionContext() == .explicitWorkspaceResume)
        #expect(model.takePendingSelectionContext() == nil)

        model.setPendingSelectionContext(.directInteraction)
        model.setPendingSelectionContext(nil)
        #expect(model.takePendingSelectionContext() == nil)
    }

    @Test func noIndicatorsMeansNoMutationsAndFalse() {
        let (model, host, workspaceId, panelId) = makeModel()
        #expect(!model.dismissNotificationOnDirectInteraction(workspaceId: workspaceId, surfaceId: panelId))
        #expect(host.log.isEmpty)
    }

    // MARK: suppressOnlyFocusedSurface (issue #6601)

    @Test func suppressOnlyFocusedSurfaceBlocksImplicitDismissOfNonFocusedSurface() {
        let (model, host, workspaceId, panelId) = makeModel()
        let otherSurface = UUID()
        host.focusedSurfaceIds[workspaceId] = panelId
        host.unreadNotificationSurfaces = [otherSurface]
        host.suppressOnlyFocusedSurface = true

        // Implicit (app-active) auto-withdraw targeting a non-focused surface is
        // suppressed: the banner stays up until that surface is focused.
        #expect(!model.dismissNotification(
            workspaceId: workspaceId, surfaceId: otherSurface, context: .activeFocus
        ))
        #expect(host.log.isEmpty)
    }

    @Test func suppressOnlyFocusedSurfaceStillDismissesFocusedSurface() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.focusedSurfaceIds[workspaceId] = panelId
        host.unreadNotificationSurfaces = [panelId]
        host.suppressOnlyFocusedSurface = true

        // The exact focused surface is still dismissed on active focus.
        #expect(model.dismissNotification(
            workspaceId: workspaceId, surfaceId: panelId, context: .activeFocus
        ))
        #expect(host.log.contains("markRead:\(panelId.uuidString.prefix(4))"))
    }

    @Test func suppressOnlyFocusedSurfaceOffPreservesLegacyImplicitWithdraw() {
        let (model, host, workspaceId, panelId) = makeModel()
        let otherSurface = UUID()
        host.focusedSurfaceIds[workspaceId] = panelId
        host.unreadNotificationSurfaces = [otherSurface]
        // Flag defaults to off: legacy workspace-visibility withdraw proceeds.

        #expect(model.dismissNotification(
            workspaceId: workspaceId, surfaceId: otherSurface, context: .activeFocus
        ))
        #expect(host.log.contains("markRead:\(otherSurface.uuidString.prefix(4))"))
    }

    @Test func suppressOnlyFocusedSurfaceDoesNotNarrowExplicitInteraction() {
        let (model, host, workspaceId, panelId) = makeModel()
        let otherSurface = UUID()
        host.focusedSurfaceIds[workspaceId] = panelId
        host.unreadNotificationSurfaces = [otherSurface]
        host.suppressOnlyFocusedSurface = true

        // Direct interaction is explicit (does not require an active app), so it
        // dismisses the targeted surface even when it is not focused.
        #expect(model.dismissNotificationOnDirectInteraction(
            workspaceId: workspaceId, surfaceId: otherSurface
        ))
        #expect(host.log.contains("markRead:\(otherSurface.uuidString.prefix(4))"))
    }

    @Test func suppressOnlyFocusedSurfaceLeavesWorkspaceLevelDismissBroad() {
        let (model, host, workspaceId, panelId) = makeModel()
        host.focusedSurfaceIds[workspaceId] = panelId
        host.workspaceWideUnread = [workspaceId]
        host.suppressOnlyFocusedSurface = true

        // Workspace-level (surfaceId == nil) dismissals stay broad.
        #expect(model.dismissNotification(
            workspaceId: workspaceId, surfaceId: nil, context: .activeFocus
        ))
        #expect(host.log.contains("markRead:nil"))
    }
}
