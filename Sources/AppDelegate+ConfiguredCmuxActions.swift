import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Configured cmux action execution
extension AppDelegate {
    func executeConfiguredCmuxActionShortcut(
        _ action: CmuxResolvedConfigAction,
        event: NSEvent,
        context: MainWindowContext?
    ) -> Bool {
        guard let context else { return false }
        return executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    /// Public entry for the sidebar group `+` right-click context menu: runs a
    /// resolved configured action and, on success for "new workspace" style
    /// builtIns, joins the newly-created workspace to the given group.
    @discardableResult
    func runWorkspaceGroupConfiguredAction(
        _ action: CmuxResolvedConfigAction,
        tabManager: TabManager,
        groupId: UUID
    ) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) else {
            return false
        }
        let anchorId = tabManager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId
        let groupPlacement: WorkspaceGroupNewPlacement = {
            let cwd = anchorId.flatMap { id in
                tabManager.tabs.first(where: { $0.id == id })?.currentDirectory
            }
            let configured = context.cmuxConfigStore?.resolveWorkspaceGroupConfig(forCwd: cwd)?.newWorkspacePlacement
            return configured ?? WorkspaceGroupNewWorkspacePlacementSettings.resolved()
        }()
        // Short-circuit the built-in `newWorkspace` action: it must go through
        // createWorkspaceInGroup so the new workspace inherits the anchor's
        // cwd and honors the group's configured placement, matching
        // the bare `+` button. The generic executor below uses addWorkspace()
        // which skips both behaviors.
        if case .builtIn(.newWorkspace) = action.action {
            return tabManager.createWorkspaceInGroup(
                groupId: groupId,
                placement: groupPlacement,
                referenceWorkspaceId: anchorId
            ) != nil
        }
        // Snapshot tab ids BEFORE the action fires so the onExecuted callback
        // (which runs after any confirmation/authorization flow completes) can
        // diff against the pre-action state and join the newly-created
        // workspace to the group. The previous post-call diff missed actions
        // gated on a first-run trust prompt because the workspace doesn't
        // exist until the user grants permission.
        let beforeIds = Set(tabManager.tabs.map(\.id))
        // Group menu actions should run as if the anchor were the active
        // workspace: the executor derives the new workspace's cwd from
        // `context.tabManager.selectedWorkspace`, and a group menu item is
        // conceptually scoped to the anchor's cwd (that's how it was matched
        // in `workspaceGroups.byCwd` in the first place). Temporarily switch
        // selection to the anchor for the duration of the action; if the user
        // had a different workspace focused before, restore it once the
        // action's onExecuted fires. Skipped when no action workspace was
        // created so we don't strand selection on the anchor.
        let previousSelectedId = tabManager.selectedTabId
        if let anchorId, anchorId != previousSelectedId,
           tabManager.tabs.contains(where: { $0.id == anchorId }) {
            tabManager.selectedTabId = anchorId
        }
        var asyncObserverId: UUID?
        let onExecuted: () -> Void = { [weak tabManager, groupId, beforeIds, previousSelectedId, anchorId, groupPlacement, action] in
            guard let tabManager else { return }
            let afterIds = tabManager.tabs.map(\.id)
            var newlyCreatedId: UUID?
            for id in afterIds where !beforeIds.contains(id) {
                tabManager.addWorkspaceToGroup(
                    workspaceId: id,
                    groupId: groupId,
                    placement: groupPlacement,
                    referenceWorkspaceId: anchorId
                )
                newlyCreatedId = id
                break
            }
            // cloudVM launches a `cmux vm new` process and returns before the
            // workspace appears in tabs[]. The synchronous diff above misses
            // it, so watch the tab list while the process is running. Process
            // completion also reports the created workspace UUID as an exact
            // fallback.
            if newlyCreatedId == nil, case .builtIn(.cloudVM) = action.action {
                asyncObserverId = ConfiguredGroupActionAsyncWorkspaceObserver.install(
                    tabManager: tabManager,
                    groupId: groupId,
                    knownIds: Set(afterIds),
                    placement: groupPlacement,
                    referenceWorkspaceId: anchorId
                )
            }
            // Restore the prior selection if the action didn't create a new
            // workspace (the gesture wasn't "go work in the new one") and
            // the previous selection still exists. When a new workspace was
            // created, leave it focused — that matches what the equivalent
            // bare `+` button does.
            if newlyCreatedId == nil,
               let previousSelectedId,
               previousSelectedId != tabManager.selectedTabId,
               tabManager.tabs.contains(where: { $0.id == previousSelectedId }) {
                tabManager.selectedTabId = previousSelectedId
            }
        }
        let onCloudVMCompletion: (CloudVMActionLauncher.Completion) -> Void = { [weak tabManager] completion in
            guard let tabManager, let asyncObserverId else { return }
            ConfiguredGroupActionAsyncWorkspaceObserver.finishPending(
                tabManager: tabManager,
                observerId: asyncObserverId,
                workspaceId: completion.succeeded ? completion.workspaceId : nil
            )
        }
        let didRun = executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: resolvedWindow(for: context),
            onExecuted: onExecuted,
            onCloudVMCompletion: onCloudVMCompletion
        )
        // executeConfiguredCmuxAction returns false when the action couldn't
        // start at all (unresolved action ref, missing target terminal, etc.).
        // In that case onExecuted will never fire, so restore the prior
        // selection here. The trust-prompt-cancelled window (action returns
        // true but the user later cancels) leaves selection on the anchor
        // until the user clicks something else; tradeoff documented at the
        // call site.
        if !didRun,
           let previousSelectedId,
           previousSelectedId != tabManager.selectedTabId,
           tabManager.tabs.contains(where: { $0.id == previousSelectedId }) {
            tabManager.selectedTabId = previousSelectedId
        }
        return didRun
    }

    func executeConfiguredCmuxAction(
        _ action: CmuxResolvedConfigAction,
        context: MainWindowContext,
        preferredWindow: NSWindow? = nil,
        onExecuted: (() -> Void)? = nil,
        onCloudVMCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil
    ) -> Bool {
        switch action.action {
        case .builtIn(let builtIn):
            switch builtIn {
            case .newWorkspace:
                context.tabManager.addWorkspace()
                onExecuted?()
                return true
            case .cloudVM:
                let didStart = performCloudVMAction(
                    tabManager: context.tabManager,
                    preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
                    debugSource: "configured.cmux.cloudvm",
                    onCompletion: onCloudVMCompletion
                )
                if didStart { onExecuted?() }
                return didStart
            case .newTerminal:
                context.tabManager.newSurface()
                onExecuted?()
                return true
            case .newBrowser:
                let previousTabManager = tabManager
                tabManager = context.tabManager
                defer { tabManager = previousTabManager }
                guard openBrowserAndFocusAddressBar(insertAtEnd: true) != nil else {
                    return false
                }
                onExecuted?()
                return true
            case .splitRight:
                if shouldSuppressSplitShortcutForTransientTerminalFocusState(
                    direction: .right,
                    tabManager: context.tabManager
                ) {
                    return true
                }
                let didSplit = performSplitShortcut(
                    direction: .right,
                    preferredWindow: preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
                )
                if didSplit { onExecuted?() }
                return didSplit
            case .splitDown:
                if shouldSuppressSplitShortcutForTransientTerminalFocusState(
                    direction: .down,
                    tabManager: context.tabManager
                ) {
                    return true
                }
                let didSplit = performSplitShortcut(
                    direction: .down,
                    preferredWindow: preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
                )
                if didSplit { onExecuted?() }
                return didSplit
            }
        case .command, .agent, .workspaceCommand:
            guard let cmuxConfigStore = context.cmuxConfigStore else {
                return false
            }
            let rawCwd = context.tabManager.selectedWorkspace?.currentDirectory
            let baseCwd = (rawCwd?.isEmpty == false) ? rawCwd!
                : FileManager.default.homeDirectoryForCurrentUser.path
            return CmuxConfigExecutor.execute(
                action: action,
                commands: cmuxConfigStore.loadedCommands,
                commandSourcePaths: cmuxConfigStore.commandSourcePaths,
                tabManager: context.tabManager,
                baseCwd: baseCwd,
                globalConfigPath: cmuxConfigStore.globalConfigPath,
                presentingWindow: preferredWindow,
                onExecuted: onExecuted
            )
        case .actionReference:
            return false
        }
    }

}
