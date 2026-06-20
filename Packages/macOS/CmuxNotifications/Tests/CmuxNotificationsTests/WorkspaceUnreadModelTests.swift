import Foundation
import Testing
import CmuxCore
@testable import CmuxNotifications

/// Recording fake host for ``WorkspaceUnreadModel``: scriptable live-state reads
/// plus an ordered log of every badge/notification-store side effect, so the
/// tests pin the exact behavior the legacy `Workspace` unread methods produced.
@MainActor
private final class FakeUnreadHost: WorkspaceUnreadHosting {
    var existingPanels: Set<UUID> = []
    var tabPanels: Set<UUID> = []
    var visibleIndicatorPanels: Set<UUID> = []
    var unreadNotificationPanels: Set<UUID> = []
    var focusedReadPanelId: UUID?
    var workspaceManualUnread = false
    var representativePanelId: UUID?

    var badgeWrites: [(panel: UUID, shows: Bool)] = []
    var derivedUnreadWrites: [Bool] = []
    var markReadPanels: [UUID] = []
    var markReadWorkspaceCount = 0
    var clearRestoredCount = 0
    var panelFlashes: [(panel: UUID, reason: WorkspaceAttentionFlashReason)] = []

    func workspaceUnreadPanelExists(_ panelId: UUID) -> Bool { existingPanels.contains(panelId) }
    func workspaceUnreadPanelIds() -> Set<UUID> { existingPanels }
    func workspaceUnreadPanelHasTab(_ panelId: UUID) -> Bool { tabPanels.contains(panelId) }
    func workspaceUnreadHasVisibleNotificationIndicator(panelId: UUID) -> Bool {
        visibleIndicatorPanels.contains(panelId)
    }
    func workspaceUnreadHasUnreadNotification(panelId: UUID) -> Bool {
        unreadNotificationPanels.contains(panelId)
    }
    func workspaceUnreadFocusedReadPanelId() -> UUID? { focusedReadPanelId }
    func workspaceUnreadTriggerPanelFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        panelFlashes.append((panelId, reason))
    }
    func workspaceUnreadNotificationHasManualUnread() -> Bool { workspaceManualUnread }
    func workspaceUnreadRepresentativePanelId() -> UUID? { representativePanelId }
    func workspaceUnreadApplyBadge(panelId: UUID, showsNotificationBadge: Bool) {
        guard tabPanels.contains(panelId) else { return }
        badgeWrites.append((panelId, showsNotificationBadge))
    }
    func workspaceUnreadSetPanelDerivedUnread(_ isUnread: Bool) { derivedUnreadWrites.append(isUnread) }
    func workspaceUnreadNotificationMarkRead(panelId: UUID) { markReadPanels.append(panelId) }
    func workspaceUnreadNotificationMarkReadWorkspace() { markReadWorkspaceCount += 1 }
    func workspaceUnreadNotificationClearRestoredUnreadIndicator() { clearRestoredCount += 1 }
}

@MainActor
private func makeModel(_ host: FakeUnreadHost) -> WorkspaceUnreadModel {
    let model = WorkspaceUnreadModel()
    model.attach(host: host)
    return model
}

@Suite @MainActor
struct WorkspaceUnreadModelTests {
    @Test func markPanelUnreadInsertsAndSyncsBadge() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)

        model.markPanelUnread(panel)

        #expect(model.manualUnreadPanelIds == [panel])
        #expect(model.manualUnreadMarkedAt[panel] != nil)
        // didSet on manualUnreadPanelIds derives workspace unread = true.
        #expect(host.derivedUnreadWrites.last == true)
        // syncUnreadBadgeStateForPanel applied a badge=true write.
        #expect(host.badgeWrites.last?.shows == true)
    }

    @Test func markPanelUnreadIgnoresMissingPanel() {
        let host = FakeUnreadHost()
        let model = makeModel(host)
        model.markPanelUnread(UUID())
        #expect(model.manualUnreadPanelIds.isEmpty)
        #expect(host.badgeWrites.isEmpty)
    }

    @Test func markPanelUnreadClearsRestoredIndicator() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)
        model.restorePanelUnreadIndicator(panel, contributesToWorkspaceUnread: true)
        #expect(model.restoredUnreadPanelIds == [panel])

        model.markPanelUnread(panel)

        #expect(model.restoredUnreadPanelIds.isEmpty)
        #expect(model.manualUnreadPanelIds == [panel])
    }

    @Test func markPanelReadClearsManualAndRestoredAndMarksStoreRead() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)
        model.markPanelUnread(panel)

        model.markPanelRead(panel)

        #expect(model.manualUnreadPanelIds.isEmpty)
        #expect(model.manualUnreadMarkedAt[panel] == nil)
        #expect(host.markReadPanels == [panel])
    }

    @Test func markPanelReadClearsWorkspaceRestoredWhenLastContributor() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)
        model.restorePanelUnreadIndicator(panel, contributesToWorkspaceUnread: true)

        model.markPanelRead(panel)

        // Last contributing restored indicator cleared -> store clear invoked once.
        #expect(host.clearRestoredCount == 1)
        #expect(model.restoredUnreadPanelIds.isEmpty)
    }

    @Test func markPanelReadDoesNotClearWorkspaceRestoredWhenOthersRemain() {
        let host = FakeUnreadHost()
        let a = UUID(), b = UUID()
        host.existingPanels = [a, b]
        host.tabPanels = [a, b]
        let model = makeModel(host)
        model.restorePanelUnreadIndicator(a, contributesToWorkspaceUnread: true)
        model.restorePanelUnreadIndicator(b, contributesToWorkspaceUnread: true)

        model.markPanelRead(a)

        #expect(host.clearRestoredCount == 0)
        #expect(model.restoredUnreadPanelIds == [b])
    }

    @Test func restoreVisualOnlyDoesNotContributeToWorkspaceUnread() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)

        model.restorePanelUnreadIndicator(panel, contributesToWorkspaceUnread: false)

        #expect(model.hasRestoredUnreadIndicator(panelId: panel))
        #expect(model.restoredUnreadIndicatorContributesToWorkspace(panelId: panel) == false)
        #expect(model.hasWorkspaceContributingRestoredUnreadIndicator == false)
        // didSet derived-unread reflects no manual + no contributing restored.
        #expect(host.derivedUnreadWrites.last == false)
    }

    @Test func preferredJumpPicksMostRecentManualPanel() {
        let host = FakeUnreadHost()
        let older = UUID(), newer = UUID()
        host.existingPanels = [older, newer]
        host.tabPanels = [older, newer]
        let model = makeModel(host)
        model.markPanelUnread(older)
        model.manualUnreadMarkedAt[older] = Date(timeIntervalSince1970: 1)
        model.markPanelUnread(newer)
        model.manualUnreadMarkedAt[newer] = Date(timeIntervalSince1970: 2)

        #expect(model.preferredUnreadPanelIdForJump() == newer)
    }

    @Test func preferredJumpFallsBackToRestoredThenRepresentative() {
        let host = FakeUnreadHost()
        let restored = UUID()
        let representative = UUID()
        host.existingPanels = [restored]
        host.tabPanels = [restored]
        host.representativePanelId = representative
        let model = makeModel(host)
        model.restorePanelUnreadIndicator(restored, contributesToWorkspaceUnread: true)

        #expect(model.preferredUnreadPanelIdForJump() == restored)

        model.clearRestoredUnreadIndicator(panelId: restored)
        #expect(model.preferredUnreadPanelIdForJump() == representative)
    }

    @Test func clearUnreadAfterJumpMarksPanelReadWhenUnread() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)
        model.markPanelUnread(panel)

        model.clearUnreadAfterJump(panelId: panel)

        #expect(model.manualUnreadPanelIds.isEmpty)
        #expect(host.markReadPanels == [panel])
        #expect(host.markReadWorkspaceCount == 0)
    }

    @Test func clearUnreadAfterJumpMarksWorkspaceReadWhenPanelNotUnread() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)

        model.clearUnreadAfterJump(panelId: panel)

        #expect(host.markReadWorkspaceCount == 1)
        #expect(host.markReadPanels.isEmpty)
    }

    @Test func clearUnreadAfterJumpNilPanelMarksWorkspaceRead() {
        let host = FakeUnreadHost()
        let model = makeModel(host)
        model.clearUnreadAfterJump(panelId: nil)
        #expect(host.markReadWorkspaceCount == 1)
    }

    @Test func clearAllForWorkspaceReadEmptiesEverythingAndReportsHadIndicators() {
        let host = FakeUnreadHost()
        let a = UUID(), b = UUID()
        host.existingPanels = [a, b]
        host.tabPanels = [a, b]
        let model = makeModel(host)
        model.markPanelUnread(a)
        model.restorePanelUnreadIndicator(b, contributesToWorkspaceUnread: true)

        let had = model.clearAllPanelUnreadIndicatorsForWorkspaceRead()

        #expect(had == true)
        #expect(model.manualUnreadPanelIds.isEmpty)
        #expect(model.restoredUnreadPanelIds.isEmpty)
        #expect(model.manualUnreadMarkedAt.isEmpty)
    }

    @Test func clearAllForWorkspaceReadReturnsFalseWhenNoLocalIndicators() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)

        // Panels exist but no local unread indicators set.
        #expect(model.clearAllPanelUnreadIndicatorsForWorkspaceRead() == false)
    }

    @Test func syncBadgeSkipsPanelWithoutTab() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        // No tab for the panel.
        let model = makeModel(host)

        model.syncUnreadBadgeStateForPanel(panel)

        #expect(host.badgeWrites.isEmpty)
    }

    @Test func shouldShowUnreadIndicatorMatchesLegacyTruthTable() {
        #expect(WorkspaceUnreadModel.shouldShowUnreadIndicator(
            hasUnreadNotification: true, hasPanelUnreadIndicator: false) == true)
        #expect(WorkspaceUnreadModel.shouldShowUnreadIndicator(
            hasUnreadNotification: false, hasPanelUnreadIndicator: true) == true)
        #expect(WorkspaceUnreadModel.shouldShowUnreadIndicator(
            hasUnreadNotification: false, hasPanelUnreadIndicator: false,
            isWorkspaceManuallyUnread: true, isWorkspaceManualUnreadRepresentative: true) == true)
        #expect(WorkspaceUnreadModel.shouldShowUnreadIndicator(
            hasUnreadNotification: false, hasPanelUnreadIndicator: false,
            isWorkspaceManuallyUnread: true, isWorkspaceManualUnreadRepresentative: false) == false)
        #expect(WorkspaceUnreadModel.shouldShowUnreadIndicator(
            hasUnreadNotification: false, hasPanelUnreadIndicator: false) == false)
    }

    @Test func willChangeFiresOnManualUnreadMutationButNotOnMarkedAt() {
        let host = FakeUnreadHost()
        let panel = UUID()
        host.existingPanels = [panel]
        host.tabPanels = [panel]
        let model = makeModel(host)
        var fireCount = 0
        model.willChange = { fireCount += 1 }

        model.manualUnreadPanelIds = [panel]
        #expect(fireCount == 1)

        // manualUnreadMarkedAt is not @Published-equivalent: no willChange.
        model.manualUnreadMarkedAt[panel] = Date()
        #expect(fireCount == 1)

        model.restoredUnreadPanelIndicators[panel] = .workspaceUnread
        #expect(fireCount == 2)
    }

    // MARK: - Attention flash

    @Test func hasIndicatorReadsForwardToHost() {
        let host = FakeUnreadHost()
        let visible = UUID(), unread = UUID(), neither = UUID()
        host.visibleIndicatorPanels = [visible]
        host.unreadNotificationPanels = [unread]
        let model = makeModel(host)

        #expect(model.hasVisibleNotificationIndicator(panelId: visible) == true)
        #expect(model.hasVisibleNotificationIndicator(panelId: neither) == false)
        #expect(model.hasUnreadNotification(panelId: unread) == true)
        #expect(model.hasUnreadNotification(panelId: neither) == false)
    }

    @Test func attentionPersistentStateUnionsRestoredAndNotificationUnread() {
        let host = FakeUnreadHost()
        let restored = UUID(), notified = UUID(), manual = UUID(), focusedRead = UUID()
        host.existingPanels = [restored, notified, manual]
        host.tabPanels = [restored, notified, manual]
        host.unreadNotificationPanels = [notified]
        host.focusedReadPanelId = focusedRead
        let model = makeModel(host)
        model.restorePanelUnreadIndicator(restored, contributesToWorkspaceUnread: true)
        model.markPanelUnread(manual)

        let state = model.attentionPersistentState()

        #expect(state.unreadPanelIDs == [restored, notified])
        #expect(state.focusedReadPanelID == focusedRead)
        #expect(state.manualUnreadPanelIDs == [manual])
    }

    @Test func requestNavigationFlashSuppressedWhenAnotherPanelCompetes() {
        let host = FakeUnreadHost()
        let target = UUID(), competitor = UUID()
        host.existingPanels = [target, competitor]
        host.tabPanels = [target, competitor]
        host.unreadNotificationPanels = [competitor]
        let model = makeModel(host)

        model.requestAttentionFlash(panelId: target, reason: .navigation)

        // competitor carries an unread indicator -> navigation flash suppressed.
        #expect(host.panelFlashes.isEmpty)
    }

    @Test func requestNavigationFlashAllowedWhenOnlyTargetCompetes() {
        let host = FakeUnreadHost()
        let target = UUID()
        host.existingPanels = [target]
        host.tabPanels = [target]
        host.unreadNotificationPanels = [target]
        let model = makeModel(host)

        model.requestAttentionFlash(panelId: target, reason: .navigation)

        #expect(host.panelFlashes.count == 1)
        #expect(host.panelFlashes.first?.panel == target)
        #expect(host.panelFlashes.first?.reason == .navigation)
    }

    @Test func requestNonNavigationFlashAlwaysPlays() {
        let host = FakeUnreadHost()
        let target = UUID(), competitor = UUID()
        host.existingPanels = [target, competitor]
        host.tabPanels = [target, competitor]
        host.unreadNotificationPanels = [competitor]
        let model = makeModel(host)

        for reason: WorkspaceAttentionFlashReason in [.notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug] {
            model.requestAttentionFlash(panelId: target, reason: reason)
        }

        #expect(host.panelFlashes.map(\.reason) ==
            [.notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug])
    }

    @Test func triggerWorkspacePaneFlashSetsMirrorsAndBumpsToken() {
        let host = FakeUnreadHost()
        let panel = UUID()
        let model = makeModel(host)

        model.triggerWorkspacePaneFlash(panelId: panel, reason: .notificationArrival)
        #expect(model.tmuxWorkspaceFlashPanelId == panel)
        #expect(model.tmuxWorkspaceFlashReason == .notificationArrival)
        #expect(model.tmuxWorkspaceFlashToken == 1)

        // A repeat for the same panel/reason still bumps the token so the
        // overlay re-triggers.
        model.triggerWorkspacePaneFlash(panelId: panel, reason: .notificationArrival)
        #expect(model.tmuxWorkspaceFlashToken == 2)
    }

    @Test func tmuxFlashMirrorsFireWillChange() {
        let host = FakeUnreadHost()
        let model = makeModel(host)
        var fireCount = 0
        model.willChange = { fireCount += 1 }

        model.triggerWorkspacePaneFlash(panelId: UUID(), reason: .debug)
        // panelId + reason + token writes each fire willChange (legacy
        // @Published private(set) parity).
        #expect(fireCount == 3)
    }
}
