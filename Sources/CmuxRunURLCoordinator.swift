import AppKit
import Bonsplit
import CmuxPanes
import Foundation

@MainActor
final class CmuxRunURLCoordinator {
    private unowned let appDelegate: AppDelegate
    private let directoryResolver: CmuxRunWorkingDirectoryResolver
    private let confirmationPresenter: CmuxRunURLConfirmationPresenter

    init(
        appDelegate: AppDelegate,
        directoryResolver: CmuxRunWorkingDirectoryResolver = CmuxRunWorkingDirectoryResolver(),
        confirmationPresenter: CmuxRunURLConfirmationPresenter? = nil
    ) {
        self.appDelegate = appDelegate
        self.directoryResolver = directoryResolver
        self.confirmationPresenter = confirmationPresenter ?? CmuxRunURLConfirmationPresenter()
    }

    @discardableResult
    func handle(_ request: CmuxRunURLRequest) -> Bool {
        if appDelegate.shouldDeferNavigationURLRequestsForStartupRestore {
            if appDelegate.pendingStartupRunURLRequest == nil {
                appDelegate.pendingStartupRunURLRequest = request
            } else {
                confirmationPresenter.showFailure(.busy)
            }
            return true
        }
        guard !appDelegate.isHandlingCmuxRunURLRequest else {
            confirmationPresenter.showFailure(.busy)
            return true
        }

        let workingDirectory: String
        switch directoryResolver.resolve(request.workingDirectory) {
        case .success(let path):
            workingDirectory = path
        case .failure(let error):
            confirmationPresenter.showFailure(error)
            return true
        }

        let plan: CmuxRunExecutionPlan
        switch makePlan(request: request, workingDirectory: workingDirectory) {
        case .success(let resolvedPlan):
            plan = resolvedPlan
        case .failure(let error):
            confirmationPresenter.showFailure(error)
            return true
        }

        appDelegate.isHandlingCmuxRunURLRequest = true
        defer { appDelegate.isHandlingCmuxRunURLRequest = false }
        appDelegate.deferInitialMainWindowBootstrapForExternalConfirmation()
        let preferredWindow = window(for: plan.target)
        guard confirmationPresenter.confirm(plan, presentingWindow: preferredWindow) else {
            cmuxDebugLog("runURL.cancelled")
            appDelegate.resumeInitialMainWindowBootstrapAfterExternalConfirmation(
                debugSource: "runURL.cancelled"
            )
            return true
        }

        appDelegate.prepareForExplicitOpenIntentAtStartup()
        appDelegate.bootstrapInitialMainWindowAfterAcceptedExternalOpen(
            debugSource: "runURL.confirmed",
            suppressWelcome: true
        )
        switch execute(plan) {
        case .success:
            cmuxDebugLog("runURL.executed")
        case .failure(let error):
            cmuxDebugLog("runURL.executionFailed error=\(error)")
            confirmationPresenter.showFailure(error, presentingWindow: preferredWindow)
        }
        return true
    }

    func makePlan(
        request: CmuxRunURLRequest,
        workingDirectory: String
    ) -> Result<CmuxRunExecutionPlan, CmuxRunURLExecutionError> {
        switch request.placement {
        case .workspace:
            guard let context = appDelegate.preferredRegisteredMainWindowContext(),
                  appDelegate.windowForMainWindowId(context.windowId) != nil else {
                return .failure(.targetNotFound)
            }
            let selectedWorkspaceTitle = context.tabManager.selectedTabId.flatMap { workspaceId in
                context.tabManager.resolvedWorkspaceDisplayTitles(for: [workspaceId])[workspaceId]
            } ?? String(localized: "dialog.runURL.target.workspace", defaultValue: "Workspace")
            return .success(
                CmuxRunExecutionPlan(
                    command: request.command,
                    workingDirectory: workingDirectory,
                    target: .workspace(
                        windowId: context.windowId,
                        tabManagerIdentity: ObjectIdentifier(context.tabManager)
                    ),
                    placementDescription: String(
                        localized: "dialog.runURL.placement.workspace",
                        defaultValue: "New workspace"
                    ),
                    targetDescription: String(
                        format: String(
                            localized: "dialog.runURL.target.activeWindow",
                            defaultValue: "Window %@, current workspace: %@"
                        ),
                        String(context.windowId.uuidString.prefix(8)),
                        selectedWorkspaceTitle
                    )
                )
            )

        case .surface, .pane:
            guard let workspaceId = request.workspaceId,
                  let anchor = request.anchor else {
                return .failure(.targetNotFound)
            }
            let navigationTarget: CmuxNavigationURLRequest.Target
            switch anchor {
            case .pane(let paneId):
                navigationTarget = .pane(workspaceId: workspaceId, paneId: paneId)
            case .surface(let surfaceId):
                navigationTarget = .surface(workspaceId: workspaceId, surfaceId: surfaceId)
            }
            let resolver = CmuxNavigationTargetResolver(
                workspaces: appDelegate.cmuxNavigationWorkspaceDescriptors()
            )
            guard let resolution = resolver.resolve(navigationTarget) else {
                return .failure(.targetNotFound)
            }

            let runtimeWorkspaceId: UUID
            let paneId: UUID
            let anchorPanelId: UUID?
            switch resolution {
            case .workspace:
                return .failure(.targetNotFound)
            case .pane(let resolvedWorkspaceId, let resolvedPaneId):
                runtimeWorkspaceId = resolvedWorkspaceId
                paneId = resolvedPaneId
                anchorPanelId = nil
            case .surface(let resolvedWorkspaceId, let panelId):
                runtimeWorkspaceId = resolvedWorkspaceId
                guard let manager = appDelegate.tabManagerFor(tabId: runtimeWorkspaceId),
                      let workspace = manager.tabs.first(where: { $0.id == runtimeWorkspaceId }),
                      let resolvedPane = workspace.paneId(forPanelId: panelId) else {
                    return .failure(.targetNotFound)
                }
                paneId = resolvedPane.id
                anchorPanelId = panelId
            }

            guard let manager = appDelegate.tabManagerFor(tabId: runtimeWorkspaceId),
                  let windowId = appDelegate.windowId(for: manager),
                  appDelegate.windowForMainWindowId(windowId) != nil,
                  let workspace = manager.tabs.first(where: { $0.id == runtimeWorkspaceId }) else {
                return .failure(.targetNotFound)
            }
            guard workspace.remoteConfiguration == nil, !workspace.isRemoteTmuxMirror else {
                return .failure(.remoteWorkspaceUnsupported)
            }
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return .failure(.targetNotFound)
            }

            let workspaceTitle = manager.resolvedWorkspaceDisplayTitles(for: [runtimeWorkspaceId])[
                runtimeWorkspaceId
            ] ?? String(localized: "dialog.runURL.target.workspace", defaultValue: "Workspace")
            let targetDescription = String(
                format: String(
                    localized: "dialog.runURL.target.workspacePane",
                    defaultValue: "%@, pane %@"
                ),
                workspaceTitle,
                String(paneId.uuidString.prefix(8))
            )

            if request.placement == .surface {
                return .success(
                    CmuxRunExecutionPlan(
                        command: request.command,
                        workingDirectory: workingDirectory,
                        target: .surface(
                            windowId: windowId,
                            workspaceId: runtimeWorkspaceId,
                            paneId: paneId,
                            anchorPanelId: anchorPanelId
                        ),
                        placementDescription: String(
                            localized: "dialog.runURL.placement.surface",
                            defaultValue: "New tab in pane"
                        ),
                        targetDescription: targetDescription
                    )
                )
            }

            let sourcePanelId: UUID?
            if let anchorPanelId {
                sourcePanelId = anchorPanelId
            } else {
                sourcePanelId = workspace.bonsplitController.selectedTab(inPane: pane)
                    .flatMap { workspace.panelIdFromSurfaceId($0.id) }
                    ?? workspace.bonsplitController.tabs(inPane: pane).first
                        .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            }
            guard let sourcePanelId, let direction = request.direction else {
                return .failure(.emptyPane)
            }
            return .success(
                CmuxRunExecutionPlan(
                    command: request.command,
                    workingDirectory: workingDirectory,
                    target: .pane(
                        windowId: windowId,
                        workspaceId: runtimeWorkspaceId,
                        paneId: paneId,
                        sourcePanelId: sourcePanelId,
                        direction: direction
                    ),
                    placementDescription: String(
                        format: String(
                            localized: "dialog.runURL.placement.pane",
                            defaultValue: "New %@ split pane"
                        ),
                        localizedDirection(direction)
                    ),
                    targetDescription: targetDescription
                )
            )
        }
    }

    func execute(_ plan: CmuxRunExecutionPlan) -> Result<Void, CmuxRunURLExecutionError> {
        switch directoryResolver.resolve(plan.workingDirectory) {
        case .success(let path) where path == plan.workingDirectory:
            break
        case .success:
            return .failure(.targetChanged)
        case .failure:
            return .failure(.workingDirectoryNotFound)
        }

        switch plan.target {
        case .workspace(let windowId, let tabManagerIdentity):
            guard let manager = appDelegate.tabManagerFor(windowId: windowId),
                  ObjectIdentifier(manager) == tabManagerIdentity,
                  let window = appDelegate.windowForMainWindowId(windowId) else {
                return .failure(.targetChanged)
            }
            focus(window: window, windowId: windowId)
            _ = manager.addWorkspace(
                workingDirectory: plan.workingDirectory,
                initialTerminalCommand: plan.launchCommand,
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
            )
            return .success(())

        case .surface(let windowId, let workspaceId, let paneId, let anchorPanelId):
            guard let resolved = revalidatedWorkspace(
                windowId: windowId,
                workspaceId: workspaceId,
                paneId: paneId,
                anchorPanelId: anchorPanelId
            ) else {
                return .failure(.targetChanged)
            }
            guard resolved.workspace.remoteConfiguration == nil,
                  !resolved.workspace.isRemoteTmuxMirror else {
                return .failure(.remoteWorkspaceUnsupported)
            }
            focus(window: resolved.window, windowId: windowId)
            guard let newPanel = resolved.workspace.newTerminalSurface(
                inPane: resolved.pane,
                focus: false,
                workingDirectory: plan.workingDirectory,
                initialCommand: plan.launchCommand,
                preserveFocusWhenUnfocused: false,
                suppressWorkspaceRemoteStartupCommand: true
            ) else {
                return .failure(.creationFailed)
            }
            resolved.manager.focusTab(
                workspaceId,
                surfaceId: newPanel.id,
                suppressFlash: true
            )
            return .success(())

        case .pane(
            let windowId,
            let workspaceId,
            let paneId,
            let sourcePanelId,
            let direction
        ):
            guard let resolved = revalidatedWorkspace(
                windowId: windowId,
                workspaceId: workspaceId,
                paneId: paneId,
                anchorPanelId: sourcePanelId
            ) else {
                return .failure(.targetChanged)
            }
            guard resolved.workspace.remoteConfiguration == nil,
                  !resolved.workspace.isRemoteTmuxMirror else {
                return .failure(.remoteWorkspaceUnsupported)
            }
            focus(window: resolved.window, windowId: windowId)
            guard let newPanelId = resolved.manager.newSplit(
                tabId: workspaceId,
                surfaceId: sourcePanelId,
                direction: splitDirection(direction),
                focus: false,
                workingDirectory: plan.workingDirectory,
                initialCommand: plan.launchCommand
            ) else {
                return .failure(.creationFailed)
            }
            resolved.manager.focusTab(
                workspaceId,
                surfaceId: newPanelId,
                suppressFlash: true
            )
            return .success(())
        }
    }

    private func revalidatedWorkspace(
        windowId: UUID,
        workspaceId: UUID,
        paneId: UUID,
        anchorPanelId: UUID?
    ) -> (manager: TabManager, workspace: Workspace, pane: Bonsplit.PaneID, window: NSWindow)? {
        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let window = appDelegate.windowForMainWindowId(windowId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }),
              let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
            return nil
        }
        if let anchorPanelId, workspace.paneId(forPanelId: anchorPanelId)?.id != paneId {
            return nil
        }
        return (manager, workspace, pane, window)
    }

    private func window(for target: CmuxRunExecutionPlan.Target) -> NSWindow? {
        let windowId: UUID
        switch target {
        case .workspace(let id, _): windowId = id
        case .surface(let id, _, _, _): windowId = id
        case .pane(let id, _, _, _, _): windowId = id
        }
        return appDelegate.windowForMainWindowId(windowId)
    }

    private func focus(window: NSWindow, windowId: UUID) {
        appDelegate.setActiveMainWindow(window)
        _ = appDelegate.focusMainWindow(windowId: windowId)
    }

    private func splitDirection(_ direction: CmuxRunURLRequest.Direction) -> SplitDirection {
        switch direction {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }

    private func localizedDirection(_ direction: CmuxRunURLRequest.Direction) -> String {
        switch direction {
        case .left:
            return String(localized: "dialog.runURL.direction.left", defaultValue: "left")
        case .right:
            return String(localized: "dialog.runURL.direction.right", defaultValue: "right")
        case .up:
            return String(localized: "dialog.runURL.direction.up", defaultValue: "upper")
        case .down:
            return String(localized: "dialog.runURL.direction.down", defaultValue: "lower")
        }
    }
}
