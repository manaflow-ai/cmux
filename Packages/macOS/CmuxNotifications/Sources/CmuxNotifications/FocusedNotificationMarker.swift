public import Foundation

/// The focused-notification mark state machine: toggling the focused
/// notification's unread state, and marking it oldest-unread before jumping to
/// the next latest unread. Lifted verbatim from `AppDelegate`'s focused-mark
/// cluster (`toggleFocusedNotificationUnread`,
/// `markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`, the
/// `markFocusedNotificationAsOldestUnread` overloads), with every app-target
/// collaborator (`TerminalNotificationStore`, `Workspace`, the first-responder
/// `focusedTerminalShortcutContext`, the window contexts) reached through
/// ``FocusedNotificationResolving``.
///
/// A Coordinator-adjacent flow helper (CONVENTIONS §2): it sequences the
/// focused-mark flows and owns no state. The jump step is delegated back to the
/// owning ``NotificationNavigationCoordinator`` through an injected closure so
/// this type carries no jump logic of its own. `@MainActor` for parity with the
/// resolver and the legacy main-actor path.
@MainActor
public final class FocusedNotificationMarker {
    private let resolver: any FocusedNotificationResolving
    /// Delegates to `NotificationNavigationCoordinator.jumpToLatestUnread`,
    /// returning the opened notification id (or `nil`). Injected so the marker
    /// does not depend on the coordinator's other seams.
    private let jumpToLatestUnread: (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) -> UUID?
    /// Runs the same jump while retaining whether a workspace fallback opened.
    /// The legacy return value cannot distinguish a successful workspace jump
    /// from no jump because both return a `nil` notification id.
    private let jumpToLatestUnreadWithOutcome:
        (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) ->
        (openedNotificationId: UUID?, didOpen: Bool)

    /// Creates a focused-notification marker driven by the injected resolver
    /// and jump closure.
    public init(
        resolver: any FocusedNotificationResolving,
        jumpToLatestUnread: @escaping (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) -> UUID?
    ) {
        self.resolver = resolver
        self.jumpToLatestUnread = jumpToLatestUnread
        self.jumpToLatestUnreadWithOutcome = { excludedNotificationId, excludedWorkspaceId in
            let openedNotificationId = jumpToLatestUnread(excludedNotificationId, excludedWorkspaceId)
            return (openedNotificationId, openedNotificationId != nil)
        }
    }

    /// Internal composition entry point for a coordinator that can observe
    /// successful workspace fallback jumps as well as notification jumps.
    init(
        resolver: any FocusedNotificationResolving,
        jumpToLatestUnread: @escaping (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) -> UUID?,
        jumpToLatestUnreadWithOutcome: @escaping
            (_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) ->
            (openedNotificationId: UUID?, didOpen: Bool)
    ) {
        self.resolver = resolver
        self.jumpToLatestUnread = jumpToLatestUnread
        self.jumpToLatestUnreadWithOutcome = jumpToLatestUnreadWithOutcome
    }

    /// The result of marking the focused notification oldest-unread, mirroring
    /// the app-target `FocusedNotificationMarkResult`.
    private enum MarkResult {
        case deferredNotification(UUID)
        case markedWorkspaceWithoutNotification(UUID)
    }

    /// Toggles the focused notification's unread state, returning whether
    /// anything was toggled. Mirrors `toggleFocusedNotificationUnread`.
    @discardableResult
    public func toggleFocusedNotificationUnread(preferredWindowToken: AnyObject? = nil) -> Bool {
        // Mirrors `guard let notificationStore, let target = focusedNotificationTarget(...)`.
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return false
        }
        return toggleNotificationUnread(
            target: target,
            panel: resolver.focusedPanel(forTabId: target.tabId, surfaceId: target.surfaceId)
        )
    }

    /// Toggles unread state for an exact workspace/panel target.
    ///
    /// Unlike ``toggleFocusedNotificationUnread(preferredWindowToken:)``, this
    /// entry point never re-resolves the first responder or selected workspace.
    /// A deleted workspace or panel returns `.targetUnavailable` without
    /// falling back to a different live target.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace captured when the action was resolved.
    ///   - panelId: The captured panel, or `nil` for workspace-level unread.
    /// - Returns: The exact outcome of acting on the captured target.
    @discardableResult
    public func toggleNotificationUnread(
        workspaceId: UUID,
        panelId: UUID?
    ) -> ExplicitNotificationActionOutcome {
        guard resolver.hasNotificationStore,
              let (target, panel) = explicitTarget(workspaceId: workspaceId, panelId: panelId) else {
            return .targetUnavailable
        }
        _ = toggleNotificationUnread(target: target, panel: panel)
        return .completed
    }

    /// Sets unread state for an exact workspace/panel target.
    ///
    /// Repeating the same requested state is an idempotent success. A deleted
    /// workspace or panel fails closed without acting on current focus.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace captured when the action was resolved.
    ///   - panelId: The captured panel, or `nil` for workspace-level unread.
    ///   - unread: The desired unread state.
    /// - Returns: The exact outcome of acting on the captured target.
    @discardableResult
    public func setNotificationUnread(
        workspaceId: UUID,
        panelId: UUID?,
        unread: Bool
    ) -> ExplicitNotificationActionOutcome {
        guard resolver.hasNotificationStore,
              let (target, panel) = explicitTarget(workspaceId: workspaceId, panelId: panelId) else {
            return .targetUnavailable
        }
        let state = notificationUnreadState(target: target, panel: panel)
        _ = setExactNotificationUnread(target: target, panel: panel, unread: unread, state: state)
        return .completed
    }

    private func toggleNotificationUnread(
        target: FocusedNotificationTarget,
        panel: FocusedPanel?
    ) -> Bool {
        let state = notificationUnreadState(target: target, panel: panel)
        return setNotificationUnread(
            target: target,
            panel: panel,
            unread: !state.isUnread,
            state: state
        )
    }

    private func notificationUnreadState(
        target: FocusedNotificationTarget,
        panel: FocusedPanel?
    ) -> UnreadState {
        if let panel {
            let focusedPanelHasRestoredUnread = resolver.panelHasRestoredUnread(panel)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: target.tabId) &&
                !focusedPanelHasRestoredUnread &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            let readsWorkspace =
                resolver.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: nil) ||
                hasWorkspaceOnlyRestoredUnread
            let hasWorkspaceManualUnreadOnPanel =
                resolver.storeHasManualUnread(forTabId: target.tabId) &&
                resolver.panelIsRepresentativeForWorkspaceManualUnread(panel)
            let isPanelUnread =
                resolver.panelIsManualUnread(panel) ||
                focusedPanelHasRestoredUnread ||
                resolver.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: panel.panelId) ||
                hasWorkspaceManualUnreadOnPanel
            return UnreadState(
                isUnread: readsWorkspace || isPanelUnread,
                readsWorkspace: readsWorkspace,
                readsPanel: isPanelUnread,
                clearsWorkspaceManualUnread: hasWorkspaceManualUnreadOnPanel
            )
        }
        return UnreadState(
            isUnread: resolver.workspaceIsUnread(forTabId: target.tabId),
            readsWorkspace: true,
            readsPanel: false,
            clearsWorkspaceManualUnread: false
        )
    }

    private func setExactNotificationUnread(
        target: FocusedNotificationTarget,
        panel: FocusedPanel?,
        unread: Bool,
        state: UnreadState
    ) -> Bool {
        guard state.isUnread != unread else { return false }
        guard let panel else {
            if unread {
                resolver.storeMarkUnread(forTabId: target.tabId)
            } else {
                resolver.storeMarkRead(forTabId: target.tabId)
            }
            return true
        }
        if unread {
            resolver.markPanelUnread(panel)
            return true
        }
        if state.readsWorkspace {
            resolver.storeMarkRead(forTabId: target.tabId)
        }
        if state.readsPanel {
            resolver.markPanelRead(panel)
        }
        if state.clearsWorkspaceManualUnread {
            resolver.storeClearManualUnread(forTabId: target.tabId)
        }
        return true
    }

    private func setNotificationUnread(
        target: FocusedNotificationTarget,
        panel: FocusedPanel?,
        unread: Bool,
        state: UnreadState
    ) -> Bool {
        guard state.isUnread != unread else { return false }
        if let panel {
            if unread {
                resolver.markPanelUnread(panel)
            } else if state.readsWorkspace {
                resolver.storeMarkRead(forTabId: target.tabId)
            } else {
                resolver.markPanelRead(panel)
                if state.clearsWorkspaceManualUnread {
                    resolver.storeClearManualUnread(forTabId: target.tabId)
                }
            }
            return true
        }
        if unread {
            resolver.storeMarkUnread(forTabId: target.tabId)
        } else {
            resolver.storeMarkRead(forTabId: target.tabId)
        }
        return true
    }

    /// Marks the focused notification oldest-unread, then jumps to the next
    /// latest unread (excluding the deferred notification or marked workspace),
    /// returning the opened notification id. Mirrors
    /// `markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`.
    @discardableResult
    public func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindowToken: AnyObject? = nil
    ) -> UUID? {
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return nil
        }
        let mark = markNotificationAsOldestUnread(
            target: target,
            panel: resolver.focusedPanel(forTabId: target.tabId, surfaceId: target.surfaceId)
        )
        return jumpAfterMark(mark.result)
    }

    /// Marks an exact workspace/panel target oldest-unread, then jumps to the
    /// next latest unread target.
    ///
    /// Unlike the focused entry point, this method validates the captured IDs
    /// and fails closed when either one is stale.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace captured when the action was resolved.
    ///   - panelId: The captured panel, or `nil` for workspace-level unread.
    /// - Returns: The exact outcome of marking or jumping from the target.
    @discardableResult
    func markNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        workspaceId: UUID,
        panelId: UUID?
    ) -> ExplicitNotificationActionOutcome {
        guard resolver.hasNotificationStore,
              let (target, panel) = explicitTarget(workspaceId: workspaceId, panelId: panelId) else {
            return .targetUnavailable
        }
        let mark = markNotificationAsOldestUnread(target: target, panel: panel)
        let jump = jumpAfterExplicitMark(mark.result)
        return mark.didMutate || jump.didOpen ? .completed : .notApplicable
    }

    private func jumpAfterMark(_ result: MarkResult) -> UUID? {
        switch result {
        case .deferredNotification(let notificationId):
            return jumpToLatestUnread(notificationId, nil)
        case .markedWorkspaceWithoutNotification(let tabId):
            return jumpToLatestUnread(nil, tabId)
        }
    }

    private func jumpAfterExplicitMark(
        _ result: MarkResult
    ) -> (openedNotificationId: UUID?, didOpen: Bool) {
        switch result {
        case .deferredNotification(let notificationId):
            return jumpToLatestUnreadWithOutcome(notificationId, nil)
        case .markedWorkspaceWithoutNotification(let tabId):
            return jumpToLatestUnreadWithOutcome(nil, tabId)
        }
    }

    private func markNotificationAsOldestUnread(
        target: FocusedNotificationTarget,
        panel: FocusedPanel?
    ) -> (result: MarkResult, didMutate: Bool) {
        if let notificationId = resolver.markLatestNotificationAsOldestUnread(
            forTabId: target.tabId,
            surfaceId: target.surfaceId
        ) {
            return (.deferredNotification(notificationId), true)
        }
        var didMutate = false
        if let panel {
            let panelAlreadyUnread =
                resolver.panelIsManualUnread(panel) ||
                resolver.panelHasRestoredUnread(panel) ||
                resolver.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: panel.panelId)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: target.tabId) &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if !panelAlreadyUnread &&
                !resolver.storeHasManualUnread(forTabId: target.tabId) &&
                !hasWorkspaceOnlyRestoredUnread {
                resolver.markPanelUnread(panel)
                didMutate = true
            }
        } else if !resolver.workspaceIsUnread(forTabId: target.tabId) {
            resolver.storeMarkUnread(forTabId: target.tabId)
            didMutate = true
        }
        return (.markedWorkspaceWithoutNotification(target.tabId), didMutate)
    }

    private func explicitTarget(
        workspaceId: UUID,
        panelId: UUID?
    ) -> (FocusedNotificationTarget, FocusedPanel?)? {
        guard resolver.workspaceExists(forTabId: workspaceId) else { return nil }
        let target = FocusedNotificationTarget(tabId: workspaceId, surfaceId: panelId)
        guard let panelId else { return (target, nil) }
        guard let panel = resolver.focusedPanel(forTabId: workspaceId, surfaceId: panelId),
              panel.tabId == workspaceId,
              panel.panelId == panelId else {
            return nil
        }
        return (target, panel)
    }
}
