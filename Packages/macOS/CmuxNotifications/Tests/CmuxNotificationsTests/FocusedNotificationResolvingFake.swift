import Foundation
@testable import CmuxNotifications

/// Scriptable focused-notification resolver shared by the marker tests and the
/// coordinator tests. Models the focused target, the surface→panel resolution,
/// and every per-tab/per-panel unread predicate as plain dictionaries/sets, with
/// a log of the mutations so byte-identical ordering and call selection can be
/// asserted.
@MainActor
final class FakeFocusedResolving: FocusedNotificationResolving {
    var hasNotificationStore = true
    var focusedTargetValue: FocusedNotificationTarget?
    /// Panel resolution keyed by `(tabId, surfaceId)`.
    var panelByTabSurface: [PanelKey: FocusedPanel] = [:]

    var panelHasRestoredUnreadSet: Set<FocusedPanel> = []
    var workspaceHasContributingRestoredUnreadSet: Set<FocusedPanel> = []
    var panelIsManualUnreadSet: Set<FocusedPanel> = []
    var panelIsRepresentativeSet: Set<FocusedPanel> = []

    /// `(tabId, surfaceId)` pairs that show a visible indicator.
    var visibleIndicatorSet: Set<PanelKey> = []
    var storeManualUnreadTabs: Set<UUID> = []
    var storeRestoredUnreadTabs: Set<UUID> = []
    var workspaceUnreadTabs: Set<UUID> = []
    /// The notification id `markLatestNotificationAsOldestUnread` returns per tab.
    var oldestUnreadIdByTab: [UUID: UUID] = [:]

    private(set) var mutations: [String] = []

    struct PanelKey: Hashable { let tabId: UUID; let surfaceId: UUID? }

    func focusedTarget(preferredWindowToken: AnyObject?) -> FocusedNotificationTarget? {
        focusedTargetValue
    }

    func focusedPanel(forTabId tabId: UUID, surfaceId: UUID?) -> FocusedPanel? {
        panelByTabSurface[PanelKey(tabId: tabId, surfaceId: surfaceId)]
    }

    func panelHasRestoredUnread(_ panel: FocusedPanel) -> Bool {
        panelHasRestoredUnreadSet.contains(panel)
    }

    func workspaceHasContributingRestoredUnread(_ panel: FocusedPanel) -> Bool {
        workspaceHasContributingRestoredUnreadSet.contains(panel)
    }

    func panelIsManualUnread(_ panel: FocusedPanel) -> Bool {
        panelIsManualUnreadSet.contains(panel)
    }

    func panelIsRepresentativeForWorkspaceManualUnread(_ panel: FocusedPanel) -> Bool {
        panelIsRepresentativeSet.contains(panel)
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        visibleIndicatorSet.contains(PanelKey(tabId: tabId, surfaceId: surfaceId))
    }

    func storeHasManualUnread(forTabId tabId: UUID) -> Bool {
        storeManualUnreadTabs.contains(tabId)
    }

    func storeHasRestoredUnread(forTabId tabId: UUID) -> Bool {
        storeRestoredUnreadTabs.contains(tabId)
    }

    func workspaceIsUnread(forTabId tabId: UUID) -> Bool {
        workspaceUnreadTabs.contains(tabId)
    }

    func storeMarkRead(forTabId tabId: UUID) {
        mutations.append("storeMarkRead(\(short(tabId)))")
    }

    func storeMarkUnread(forTabId tabId: UUID) {
        mutations.append("storeMarkUnread(\(short(tabId)))")
    }

    func storeClearManualUnread(forTabId tabId: UUID) {
        mutations.append("storeClearManualUnread(\(short(tabId)))")
    }

    func markPanelRead(_ panel: FocusedPanel) {
        mutations.append("markPanelRead(\(short(panel.panelId)))")
    }

    func markPanelUnread(_ panel: FocusedPanel) {
        mutations.append("markPanelUnread(\(short(panel.panelId)))")
    }

    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        oldestUnreadIdByTab[tabId]
    }

    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
}
