import AppKit
import CmuxWorkspaces
import CmuxWindowing
import CmuxSettings
#if DEBUG
import CMUXDebugLog
#endif

/// Opaque per-call selection carrier for the new-workspace / cloud-VM action
/// routing, holding the legacy entrypoints' `(preferredTabManager, event,
/// preferredWindow)` app inputs. The package
/// ``WorkspaceCreationActionCoordinator`` threads it through the host without
/// inspecting it; only `AppDelegate` (the host) reads it.
@MainActor
struct WorkspaceCreationActionSelector {
    let preferredTabManager: TabManager?
    let event: NSEvent?
    let preferredWindow: NSWindow?
}

// MARK: - WorkspaceCreationActionHosting (the action coordinator's effect seam)
// `WorkspaceCreationActionCoordinator` (CmuxWorkspaces) owns the new-workspace /
// new-browser / cloud-VM routing decision logic; these witnesses invert each app
// effect it reaches. The window token is the opaque `WindowID`; this file
// resolves it back to the live `MainWindowContext` through the kept live-state
// seam (`mainWindowContexts`), per the owner ruling that the aggregate is read,
// not dissolved, in this slice. `executeConfiguredNewWorkspaceActionIfAvailable`
// stays in `AppDelegate.swift` proper (it needs `private executeConfiguredCmuxAction`).
extension AppDelegate: WorkspaceCreationActionHosting {
    typealias SelectionContext = WorkspaceCreationActionSelector

    /// Resolves a `WindowID` token to its live `MainWindowContext`.
    private func mainWindowContext(for token: WindowID) -> RegisteredMainWindow? {
        registeredMainWindows.first(where: { WindowID($0.windowId) == token })
    }

    func livePreferredWindowToken(for selector: SelectionContext) -> WindowID? {
        // Legacy `livePreferredContext`: the preferred manager's context, but
        // only when its window is live; an orphaned context is discarded.
        guard let preferredContext = selector.preferredTabManager
            .flatMap({ mainWindowContext(for: $0) }) else {
            return nil
        }
        guard resolvedWindow(for: preferredContext) != nil else {
            discardOrphanedMainWindowContext(preferredContext)
            return nil
        }
        return WindowID(preferredContext.windowId)
    }

    var hasNoMainWindows: Bool { registeredMainWindows.isEmpty }

    func preferredWindowTokenForCreation(selector: SelectionContext, debugSource: String) -> WindowID? {
        preferredMainWindowContextForWorkspaceCreation(
            event: selector.event,
            debugSource: debugSource
        ).map { WindowID($0.windowId) }
    }

    func windowTokenForCloudVM(selector: SelectionContext, debugSource: String) -> WindowID? {
        let context = selector.preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? selector.preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        return context.map { WindowID($0.windowId) }
    }

    func createMainWindowToken() -> WindowID {
        // Disambiguate from this zero-arg `WindowID`-returning witness by passing
        // the (default) `shouldActivate`; equivalent to the legacy `createMainWindow()`.
        WindowID(createMainWindow(shouldActivate: true))
    }

    func openNewMainWindow() {
        openNewMainWindow(nil)
    }

    func logFallbackNewWindow(selector: SelectionContext, source: String, reason: String) {
#if DEBUG
        logWorkspaceCreationRouting(
            phase: "fallback_new_window",
            source: source,
            reason: reason,
            event: selector.event,
            chosenContext: nil
        )
#endif
    }

    func selectedWorkspaceId(in windowToken: WindowID) -> UUID? {
        mainWindowContext(for: windowToken)?.tabManager.selectedWorkspace?.id
    }

    func addWorkspace(in windowToken: WindowID, initialSurface: NewWorkspaceInitialSurface) -> UUID? {
        guard let context = mainWindowContext(for: windowToken) else { return nil }
        return context.tabManager.addWorkspace(initialSurface: initialSurface).id
    }

    func hasPreferredTabManager(selector: SelectionContext) -> Bool {
        selector.preferredTabManager != nil
    }

    func preferredTabManagerHasNoMainWindowContext(selector: SelectionContext) -> Bool {
        guard let preferredTabManager = selector.preferredTabManager else { return false }
        return mainWindowContext(for: preferredTabManager) == nil
    }

    func addWorkspaceToPreferredTabManager(
        selector: SelectionContext,
        initialSurface: NewWorkspaceInitialSurface
    ) -> UUID? {
        guard let preferredTabManager = selector.preferredTabManager else { return nil }
        return preferredTabManager.addWorkspace(initialSurface: initialSurface).id
    }

    func createWorkspaceInGroup(
        in windowToken: WindowID,
        target: WorkspaceGroupNewWorkspaceTarget,
        initialSurface: NewWorkspaceInitialSurface
    ) -> UUID? {
        guard let context = mainWindowContext(for: windowToken) else { return nil }
        return context.tabManager.createWorkspaceInGroup(
            groupId: target.groupId,
            placement: target.placement,
            referenceWorkspaceId: target.referenceWorkspaceId,
            initialSurface: initialSurface
        )?.id
    }

    func addWorkspaceInPreferredMainWindow(
        selector: SelectionContext,
        initialSurface: NewWorkspaceInitialSurface,
        debugSource: String
    ) -> UUID? {
        addWorkspaceInPreferredMainWindow(
            initialSurface: initialSurface,
            event: selector.event,
            debugSource: debugSource
        )?.id
    }

    func focusInitialBrowserAddressBar(workspaceId: UUID) {
        // Legacy `focusInitialBrowserAddressBar(in:)` resolved the live workspace;
        // resolve it by id across the live windows, then focus its browser panel.
        guard let workspace = registeredMainWindows
            .flatMap({ $0.tabManager.tabs })
            .first(where: { $0.id == workspaceId }) else {
            return
        }
        guard let browserPanel = workspace.focusedSurfaceId.flatMap({ workspace.browserPanel(for: $0) })
            ?? workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else {
            return
        }
        workspace.focusPanel(browserPanel.id)
        focusBrowserAddressBar(in: browserPanel)
    }

    func workspaceCount(in windowToken: WindowID) -> Int {
        mainWindowContext(for: windowToken)?.tabManager.tabs.count ?? 0
    }

    func containsWorkspace(_ workspaceId: UUID, in windowToken: WindowID) -> Bool {
        mainWindowContext(for: windowToken)?.tabManager.tabs.contains(where: { $0.id == workspaceId }) ?? false
    }

    func closeWorkspace(_ workspaceId: UUID, in windowToken: WindowID) {
        guard let context = mainWindowContext(for: windowToken),
              let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return
        }
        context.tabManager.closeWorkspace(workspace, recordHistory: false)
    }

    func handleRemoteWindowNewWorkspaceRequested(in windowToken: WindowID) -> Bool {
        guard let context = mainWindowContext(for: windowToken) else { return false }
        return remoteTmuxController.handleRemoteWindowNewWorkspaceRequested(windowId: context.windowId)
    }

    var isBrowserEnabled: Bool { BrowserAvailabilitySettings.isEnabled() }

    func beep() {
        NSSound.beep()
    }

    func beepBrowserDisabled(source: String) {
#if DEBUG
        cmuxDebugLog("newBrowserWorkspace.blocked_browser_disabled source=\(source)")
#endif
        NSSound.beep()
    }

    func selectedWorkspaceGroupMembership(in windowToken: WindowID) -> WorkspaceGroupMembership? {
        guard let context = mainWindowContext(for: windowToken) else { return nil }
        let tabManager = context.tabManager
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              let selectedWorkspace = tabManager.tabs.first(where: { $0.id == selectedWorkspaceId }),
              let groupId = selectedWorkspace.groupId,
              let group = tabManager.workspaceGroups.first(where: { $0.id == groupId }) else {
            return nil
        }
        let anchorCwd = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        return WorkspaceGroupMembership(
            selectedWorkspaceId: selectedWorkspaceId,
            groupId: groupId,
            anchorCwd: anchorCwd
        )
    }

    func configuredWorkspaceGroupNewPlacement(
        in windowToken: WindowID,
        anchorCwd: String?
    ) -> WorkspaceGroupNewPlacement? {
        windowContext(for: windowToken)?.configStore?
            .resolveWorkspaceGroupConfig(forCwd: anchorCwd)?
            .newWorkspacePlacement
    }

    var defaultWorkspaceGroupNewPlacement: WorkspaceGroupNewPlacement {
        UserDefaultsSettingsClient(defaults: .standard)
            .value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
    }

    func startCloudVM(
        in windowToken: WindowID,
        selector: SelectionContext,
        onCompletion: ((CloudVMActionCompletion) -> Void)?
    ) -> Bool {
        guard let context = mainWindowContext(for: windowToken) else { return false }
        let socketPath = terminalControl.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let workspaceTitle = String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
        let existingWorkspace = existingCloudVMWorkspace(in: context.tabManager)
        let workspace: Workspace
        if let existingWorkspace {
            workspace = existingWorkspace
            context.tabManager.selectedTabId = workspace.id
            context.tabManager.setPinned(workspace, pinned: true)
            if let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
                if !loadingPanel.hasFailed {
                    onCompletion?(.init(succeeded: true, workspaceId: workspace.id))
                    return true
                }
            } else {
                onCompletion?(.init(succeeded: true, workspaceId: workspace.id))
                return true
            }
        } else {
            workspace = context.tabManager.addWorkspace(
                title: workspaceTitle,
                initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
            )
            context.tabManager.setPinned(workspace, pinned: true)
        }
        if let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
            loadingPanel.resetLoading()
        }
        let didStart = CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: resolvedWindow(for: context) ?? selector.preferredWindow,
            arguments: ["vm", "base", "open", "--workspace", workspace.id.uuidString],
            showsProgress: false,
            presentsFailureAlert: false,
            environmentOverrides: [
                "CMUX_CLOUD_ATTACH_RETRY_LIMIT": "12",
                "CMUX_CLOUD_ATTACH_RETRY_DELAY_SECONDS": "2",
            ],
            onCompletion: { completion in
                if !completion.succeeded,
                   let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
                    loadingPanel.showFailure(completion.output)
                }
                onCompletion?(.init(
                    succeeded: completion.succeeded,
                    workspaceId: completion.workspaceId
                ))
            }
        )
        if !didStart,
           let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
            loadingPanel.showFailure(String(
                localized: "panel.cloudVM.loading.failed.launch",
                defaultValue: "Cloud VM command could not be launched."
            ))
        }
        return didStart
    }

    private func existingCloudVMWorkspace(in tabManager: TabManager) -> Workspace? {
        tabManager.tabs.first { workspace in
            if workspace.panels.values.contains(where: { $0.panelType == .cloudVMLoading }) {
                return true
            }
            guard let remote = workspace.remoteConfiguration else { return false }
            return remote.persistentDaemonSlot == "cmux-default-freestyle-sshd-v1" &&
                remote.managedCloudVMID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}
