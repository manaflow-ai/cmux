import AppKit
import CmuxNotifications
import Foundation

@MainActor
extension AppDelegate {
    @discardableResult
    func openNotification(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        retargetsToLiveSurfaceOwner: Bool = true,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition? = nil
    ) -> Bool {
        // Resolve move provenance at click time. Trusted local notifications
        // follow the pane's live owner; source-confined notifications open only
        // their authorized workspace and drop a surface that moved elsewhere.
        var tabId = tabId
        var surfaceId = surfaceId
        var panelId = panelId
        var scrollPosition = scrollPosition
        let liveOwner = surfaceId.flatMap {
            notificationSurfaceOwner(surfaceID: $0, preferredTabID: tabId)
        } ?? panelId.flatMap {
            notificationSurfaceOwner(surfaceID: $0, preferredTabID: tabId)
        }
        if let owner = liveOwner {
            if owner.tabID != tabId, !retargetsToLiveSurfaceOwner {
                surfaceId = nil
                panelId = nil
                scrollPosition = nil
            } else {
                tabId = owner.tabID
                surfaceId = owner.surfaceID
                if let dock = owner.windowDock {
                    return openNotificationInWindowDock(
                        dock,
                        surfaceId: owner.surfaceID,
                        notificationId: notificationId,
                        scrollPosition: scrollPosition
                    )
                }
            }
        }
#if DEBUG
        let isJumpUnreadUITest = ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1"
        if isJumpUnreadUITest {
            writeJumpUnreadTestData([
                "jumpUnreadOpenCalled": "1",
                "jumpUnreadOpenTabId": tabId.uuidString,
                "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
            ])
        }
#endif
        guard let context = contextContainingTabId(tabId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_context"
            )
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "0", "jumpUnreadOpenUsedFallback": "1"])
            }
#endif
            let ok = openNotificationFallback(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                notificationId: notificationId,
                scrollPosition: scrollPosition
            )
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": ok ? "1" : "0"])
            }
#endif
            return ok
        }
#if DEBUG
        if isJumpUnreadUITest {
            writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "1", "jumpUnreadOpenUsedFallback": "0"])
        }
#endif
        return openNotificationInContext(
            context,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            notificationId: notificationId,
            scrollPosition: scrollPosition
        )
    }

    private func openNotificationInWindowDock(
        _ dock: DockSplitStore,
        surfaceId: UUID,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition?
    ) -> Bool {
        let target = WindowDockUnreadTarget(
            windowId: dock.workspaceId,
            surfaceId: surfaceId
        )
        guard openWindowDockUnread(target) else { return false }

        // Match direct workspace/Dock interaction: revealing a surface clears
        // every unread indicator attached to that exact destination. The id
        // clear also covers a trusted notification whose surface moved before
        // its namespace was rebound.
        notificationStore?.markRead(
            forTabId: target.windowId,
            surfaceId: target.surfaceId
        )
        notificationStore?.clearFocusedReadIndicator(
            forTabId: target.windowId,
            surfaceId: target.surfaceId
        )
        if let notificationId {
            notificationStore?.markRead(id: notificationId)
        }
        restoreWindowDockNotificationScrollPosition(
            scrollPosition,
            dock: dock,
            panelId: target.surfaceId
        )
        return true
    }

    func openNotificationInContext(
        _ context: MainWindowContext,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition? = nil
    ) -> Bool {
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        guard let window else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_window expectedIdentifier=\(expectedIdentifier)"
            )
#endif
            return false
        }

        context.sidebarSelectionState.selection = .tabs
        bringToFront(window)
        let focusSurfaceId = surfaceId ?? panelId
        let completion = notificationOpenCompletion(
            tabManager: context.tabManager,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            notificationId: notificationId,
            scrollPosition: scrollPosition
        )
        guard context.tabManager.focusTabFromNotification(
            tabId,
            surfaceId: focusSurfaceId,
            completion: completion
        ) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "focus_failed"
            )
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": "0"])
            }
#endif
            return false
        }

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: context.tabManager,
            tabId: tabId,
            expectedSurfaceId: focusSurfaceId
        )
#endif

#if DEBUG
        recordMultiWindowNotificationFocusIfNeeded(
            windowId: context.windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: context.sidebarSelectionState.selection
        )
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInContext": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

    func openNotificationFallback(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition? = nil
    ) -> Bool {
        guard let tabManager else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_tabManager"])
            }
#endif
            return false
        }
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "tab_not_in_active_manager"])
            }
#endif
            return false
        }
        guard let window = (NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_window"])
            }
#endif
            return false
        }

        sidebarSelectionState?.selection = .tabs
        bringToFront(window)
        let focusSurfaceId = surfaceId ?? panelId
        let completion = notificationOpenCompletion(
            tabManager: tabManager,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            notificationId: notificationId,
            scrollPosition: scrollPosition
        )
        guard tabManager.focusTabFromNotification(
            tabId,
            surfaceId: focusSurfaceId,
            completion: completion
        ) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData([
                    "jumpUnreadFallbackFail": "focus_failed",
                    "jumpUnreadOpenResult": "0",
                ])
            }
#endif
            return false
        }

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: focusSurfaceId
        )
#endif

#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInFallback": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

    private func notificationOpenCompletion(
        tabManager: TabManager,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition?
    ) -> (Bool) -> Void {
        { [weak self, weak tabManager] confirmed in
            guard confirmed, let self, let tabManager else { return }
            if let notificationId, let store = self.notificationStore {
                store.markRead(id: notificationId)
            }
            self.restoreNotificationScrollPosition(
                scrollPosition,
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                workspace: tabManager.tabs.first(where: { $0.id == tabId })
            )
        }
    }
}
