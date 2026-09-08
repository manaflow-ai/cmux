import AppKit
import Foundation

// MARK: - New-workspace plus-button context menu

@MainActor
final class NewWorkspaceContextMenuActionBox: NSObject {
    let windowId: UUID
    let action: CmuxResolvedConfigAction

    init(windowId: UUID, action: CmuxResolvedConfigAction) {
        self.windowId = windowId
        self.action = action
    }
}

extension AppDelegate {

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        event: NSEvent,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? mainWindowContext(forShortcutEvent: event, debugSource: debugSource)
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        guard let context,
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: cmuxConfigStore
        ) else {
            return false
        }

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
    }

    /// Pops the menu below `anchorView`, or at `location` (in `anchorView`
    /// coordinates) when the caller only knows where the click landed.
    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        at location: NSPoint? = nil,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context,
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: cmuxConfigStore
        ) else {
            return false
        }

        menu.popUp(
            positioning: nil,
            at: location ?? NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
        return true
    }

    func makeNewWorkspaceContextMenu(
        context: MainWindowContext,
        cmuxConfigStore: CmuxConfigStore
    ) -> NSMenu? {
        let model = NewWorkspaceMenuModel.build(
            newWorkspaceContextMenuItems: cmuxConfigStore.newWorkspaceContextMenuItems.filter { item in
                guard case .action(let menuAction) = item,
                      case .builtIn(let builtIn) = menuAction.action.action else { return true }
                return Self.isBuiltInActionAvailableInNewWorkspaceMenu(builtIn)
            },
            agentChatAction: resolvedBuiltInNewAgentChatAction(cmuxConfigStore: cmuxConfigStore),
            templateNames: savedLayoutNames(),
            loadedActions: cmuxConfigStore.loadedActions,
            newWorkspaceActionID: cmuxConfigStore.newWorkspaceActionID,
            deletable: { [weak self, weak cmuxConfigStore] action in
                guard let self, let cmuxConfigStore else { return false }
                return isDeletableGlobalAction(action, cmuxConfigStore: cmuxConfigStore)
            }
        )
        return renderNewWorkspaceContextMenu(
            model: model,
            context: context,
            cmuxConfigStore: cmuxConfigStore
        )
    }

    /// Feature gates for built-in plus-menu rows, evaluated when the menu
    /// opens (not at config load) so flag and setting flips apply at once.
    /// Mirrors the command palette's gates for the same actions.
    static func isBuiltInActionAvailableInNewWorkspaceMenu(_ action: CmuxSurfaceTabBarBuiltInAction) -> Bool {
        switch action {
        case .newCloudWorkspace, .cloudVM:
            return CloudMachinesFeature.isEnabled
        case .newBrowser, .newAgentChat:
            return BrowserAvailabilitySettings.isEnabled()
        case .newSimulator:
            return CmuxFeatureFlags.shared.isSimulatorEnabled
        case .mobileConnect:
            return !MobileRemoteControlPolicy.isDisabled
        case .newWorkspace, .newTerminal, .splitRight, .splitDown:
            return true
        }
    }

    private func savedLayoutNames() -> [String] {
        ((try? SavedLayoutStore().list()) ?? []).map(\.name)
    }

    private func resolvedBuiltInNewAgentChatAction(
        cmuxConfigStore: CmuxConfigStore
    ) -> CmuxResolvedConfigAction? {
        // Agent chat opens a browser surface; hide it when browser surfaces
        // are disabled, matching the command palette's browserDisabled gate.
        guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else { return nil }
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        let actionID = CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID
        let action = cmuxConfigStore.resolvedAction(id: actionID)
            ?? .builtIn(.newAgentChat)
        guard shouldAppendBuiltInNewAgentChatMenuItem(
            action,
            actionID: actionID,
            cmuxConfigStore: cmuxConfigStore
        ) else {
            return nil
        }
        return action
    }

    private func shouldAppendBuiltInNewAgentChatMenuItem(
        _ action: CmuxResolvedConfigAction,
        actionID: String,
        cmuxConfigStore: CmuxConfigStore
    ) -> Bool {
        if action.newWorkspaceMenu == false { return false }
        let configuredActionIDs = Set(cmuxConfigStore.newWorkspaceContextMenuItems.compactMap { item -> String? in
            guard case .action(let menuAction) = item else { return nil }
            return menuAction.action.id
        })
        if configuredActionIDs.contains(actionID) { return false }
        return true
    }

    @objc func performNewWorkspaceContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NewWorkspaceContextMenuActionBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        guard executeConfiguredCmuxAction(box.action, context: context, preferredWindow: window) else {
            NSSound.beep()
            return
        }
    }
}
