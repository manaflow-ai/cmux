import AppKit
import Bonsplit
import CmuxPanes
import Foundation

@MainActor
final class CmuxRunURLCoordinator {
    private unowned let appDelegate: AppDelegate
    private let directoryResolver: CmuxRunWorkingDirectoryResolver
    private let confirmationPresenter: CmuxRunURLConfirmationPresenter
    private var pendingStartupRequest: CmuxRunURLRequest?
    private var isHandlingRequest = false

    var isBusy: Bool {
        isHandlingRequest || pendingStartupRequest != nil
    }

    init(
        appDelegate: AppDelegate,
        directoryResolver: CmuxRunWorkingDirectoryResolver? = nil,
        confirmationPresenter: CmuxRunURLConfirmationPresenter? = nil
    ) {
        self.appDelegate = appDelegate
        self.directoryResolver = directoryResolver ?? CmuxRunWorkingDirectoryResolver()
        self.confirmationPresenter = confirmationPresenter ?? CmuxRunURLConfirmationPresenter()
    }

    @discardableResult
    func handle(_ request: CmuxRunURLRequest) -> Bool {
        let startsBeforeStartupRestore = request.placement == .workspace &&
            !appDelegate.didAttemptStartupSessionRestore && !appDelegate.isApplyingSessionRestore
        if Self.shouldDeferForStartupRestore(
            request: request,
            didAttemptRestore: appDelegate.didAttemptStartupSessionRestore,
            isApplyingRestore: appDelegate.isApplyingSessionRestore
        ) {
            if pendingStartupRequest == nil {
                pendingStartupRequest = request
            } else {
                confirmationPresenter.showNonModalFailure(.busy)
            }
            return true
        }
        guard !isHandlingRequest else {
            confirmationPresenter.showNonModalFailure(.busy)
            return true
        }
        if startsBeforeStartupRestore {
            appDelegate.deferInitialMainWindowBootstrapForExternalConfirmation()
        }
        isHandlingRequest = true
        Task { [self] in
            defer { isHandlingRequest = false }
            await resolvePlanConfirmAndExecute(
                request,
                resumesInitialBootstrapOnEarlyExit: startsBeforeStartupRestore
            )
        }
        return true
    }

    func flushPendingStartupRequest() {
        guard let request = pendingStartupRequest else { return }
        pendingStartupRequest = nil
        _ = handle(request)
    }

    static func shouldDeferForStartupRestore(
        request: CmuxRunURLRequest, didAttemptRestore: Bool, isApplyingRestore: Bool
    ) -> Bool {
        isApplyingRestore || (!didAttemptRestore && request.placement != .workspace)
    }

    private func resolvePlanConfirmAndExecute(
        _ request: CmuxRunURLRequest, resumesInitialBootstrapOnEarlyExit: Bool
    ) async {
        defer {
            if resumesInitialBootstrapOnEarlyExit {
                appDelegate.resumeInitialMainWindowBootstrapAfterExternalConfirmation(
                    debugSource: "runURL.completed"
                )
            }
        }
        let workingDirectory: CmuxRunResolvedWorkingDirectory
        switch await directoryResolver.resolveWithDeadline(request.workingDirectory) {
        case .success(let path):
            workingDirectory = path
        case .failure(let error):
            confirmationPresenter.showFailure(error)
            return
        }

        let plan: CmuxRunExecutionPlan
        switch makePlan(request: request, workingDirectory: workingDirectory) {
        case .success(let resolvedPlan):
            plan = resolvedPlan
        case .failure(let error):
            confirmationPresenter.showFailure(error)
            return
        }

        appDelegate.deferInitialMainWindowBootstrapForExternalConfirmation()
        let preferredWindow = window(for: plan.target)
        guard confirmationPresenter.confirm(plan, presentingWindow: preferredWindow) else {
            cmuxDebugLog("runURL.cancelled")
            appDelegate.resumeInitialMainWindowBootstrapAfterExternalConfirmation(
                debugSource: "runURL.cancelled"
            )
            return
        }

        appDelegate.prepareForExplicitOpenIntentAtStartup()
        let executionResult: Result<Void, CmuxRunURLExecutionError>
        if plan.target == .newWindow {
            executionResult = await execute(plan)
            appDelegate.bootstrapInitialMainWindowAfterAcceptedExternalOpen(
                debugSource: "runURL.confirmed.newWindow",
                suppressWelcome: true
            )
        } else {
            appDelegate.bootstrapInitialMainWindowAfterAcceptedExternalOpen(
                debugSource: "runURL.confirmed",
                suppressWelcome: true
            )
            executionResult = await execute(plan)
        }
        switch executionResult {
        case .success:
            cmuxDebugLog("runURL.executed")
        case .failure(let error):
            cmuxDebugLog("runURL.executionFailed error=\(error)")
            confirmationPresenter.showFailure(error, presentingWindow: preferredWindow)
        }
    }

    func makePlan(
        request: CmuxRunURLRequest,
        workingDirectory: CmuxRunResolvedWorkingDirectory
    ) -> Result<CmuxRunExecutionPlan, CmuxRunURLExecutionError> {
        switch request.placement {
        case .workspace:
            guard let context = appDelegate.preferredRegisteredMainWindowContext(),
                  appDelegate.windowForMainWindowId(context.windowId) != nil else {
                return .success(
                    CmuxRunExecutionPlan(
                        command: request.command,
                        workingDirectory: workingDirectory.path,
                        workingDirectoryIdentity: workingDirectory.identity,
                        target: .newWindow,
                        placementDescription: String(
                            localized: "dialog.runURL.placement.workspace",
                            defaultValue: "New workspace"
                        ),
                        targetDescription: String(
                            localized: "menu.file.newWindow",
                            defaultValue: "New Window"
                        )
                    )
                )
            }
            let workspaceFallback = String(
                localized: "dialog.runURL.target.workspace",
                defaultValue: "Workspace"
            )
            let rawSelectedWorkspaceTitle = context.tabManager.selectedTabId.flatMap { workspaceId in
                context.tabManager.resolvedWorkspaceDisplayTitles(for: [workspaceId])[workspaceId]
            } ?? workspaceFallback
            let selectedWorkspaceTitle = Self.sanitizedWorkspaceTitle(
                rawSelectedWorkspaceTitle,
                fallback: workspaceFallback
            )
            return .success(
                CmuxRunExecutionPlan(
                    command: request.command,
                    workingDirectory: workingDirectory.path,
                    workingDirectoryIdentity: workingDirectory.identity,
                    target: .workspace(
                        windowId: context.windowId,
                        tabManagerIdentity: ObjectIdentifier(context.tabManager)
                    ),
                    placementDescription: String(
                        localized: "dialog.runURL.placement.workspace",
                        defaultValue: "New workspace"
                    ),
                    targetDescription: String.localizedStringWithFormat(
                        String(
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

            let workspaceFallback = String(
                localized: "dialog.runURL.target.workspace",
                defaultValue: "Workspace"
            )
            let rawWorkspaceTitle = manager.resolvedWorkspaceDisplayTitles(for: [runtimeWorkspaceId])[
                runtimeWorkspaceId
            ] ?? workspaceFallback
            let workspaceTitle = Self.sanitizedWorkspaceTitle(
                rawWorkspaceTitle,
                fallback: workspaceFallback
            )
            let targetDescription = String.localizedStringWithFormat(
                String(
                    localized: "dialog.runURL.target.workspacePane",
                    defaultValue: "Window %@, workspace %@, pane %@: %@"
                ),
                String(windowId.uuidString.prefix(8)),
                String(runtimeWorkspaceId.uuidString.prefix(8)),
                String(paneId.uuidString.prefix(8)),
                workspaceTitle
            )

            if request.placement == .surface {
                return .success(
                    CmuxRunExecutionPlan(
                        command: request.command,
                        workingDirectory: workingDirectory.path,
                        workingDirectoryIdentity: workingDirectory.identity,
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
                    workingDirectory: workingDirectory.path,
                    workingDirectoryIdentity: workingDirectory.identity,
                    target: .pane(
                        windowId: windowId,
                        workspaceId: runtimeWorkspaceId,
                        paneId: paneId,
                        sourcePanelId: sourcePanelId,
                        direction: direction
                    ),
                    placementDescription: String.localizedStringWithFormat(
                        String(
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

    func execute(_ plan: CmuxRunExecutionPlan) async -> Result<Void, CmuxRunURLExecutionError> {
        switch await directoryResolver.resolveWithDeadline(plan.workingDirectory) {
        case .success(let resolved) where resolved == CmuxRunResolvedWorkingDirectory(
            path: plan.workingDirectory,
            identity: plan.workingDirectoryIdentity
        ):
            break
        case .success:
            return .failure(.targetChanged)
        case .failure(.workingDirectoryResolutionTimedOut):
            return .failure(.workingDirectoryResolutionTimedOut)
        case .failure(.workingDirectoryVerifierUnavailable):
            return .failure(.workingDirectoryVerifierUnavailable)
        case .failure(.workingDirectoryContainsUnsafeCharacters):
            return .failure(.workingDirectoryContainsUnsafeCharacters)
        case .failure:
            return .failure(.workingDirectoryNotFound)
        }

        switch plan.target {
        case .newWindow:
            _ = appDelegate.createMainWindow(
                initialWorkingDirectory: plan.workingDirectory,
                initialTerminalCommand: plan.launchCommand
            )
            return .success(())

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
                suppressWorkspaceRemoteStartupCommand: true,
                startupInheritance: .reviewedCommand
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
                initialCommand: plan.launchCommand,
                startupInheritance: .reviewedCommand
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

    private static func sanitizedWorkspaceTitle(_ title: String, fallback: String) -> String {
        let visibleScalars = title.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return " "
            default:
                return scalar
            }
        }
        let sanitized = String(String.UnicodeScalarView(visibleScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return sanitized.isEmpty ? fallback : sanitized
    }

    private func window(for target: CmuxRunExecutionTarget) -> NSWindow? {
        let windowId: UUID
        switch target {
        case .newWindow: return nil
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

    private func splitDirection(_ direction: CmuxRunURLDirection) -> SplitDirection {
        switch direction {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }

    private func localizedDirection(_ direction: CmuxRunURLDirection) -> String {
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
