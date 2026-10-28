import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCloudCredentials
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups

/// Owns one setup wizard. C1's authenticated transport is injected once available;
/// until then the composition root supplies a fail-closed client, and the gallery uses fakes.
@MainActor
struct CloudWorkspaceSetupFlow {
    let client: any CloudGitHubConnectorClient

    func start(_ context: AppActionContext, window: WindowState?, askedBy: String?) {
        CloudHandlers.runTracked("new Cloud workspace", context) {
            let cloud = context.services.cloud, services = context.services
            let userID = cloud.auth.user?.id, teamID = cloud.auth.teamID
            let availability = CloudWorkspaceSetupWizard.CredentialAvailability.resolve(
                teamID: cloud.auth.teamID, supportsFileRoute: cloud.configuration.linkSource == .legacy)
            let connector = CloudGitHubConnectorPresentation(client: client, center: .shared,
                isCurrent: { cloud.auth.user?.id == userID && cloud.auth.teamID == teamID })
            let present: (CmuxDialogSpec) async -> CmuxDialogAnswer = { spec in
                let scope: CmuxDialogScope = services.windows.active?.window.map(CmuxDialogScope.window) ?? .app
                if spec.identifier == "cmux.dialog.cloud.workspaceSetup" {
                    return await connector.present(spec, in: scope)
                }
                return await CmuxDialogCenter.shared.present(spec, in: scope)
            }
            let wizard = CloudWorkspaceSetupWizard()
            // Environments live in the cmux-next backend's CloudDO: only its Cloud path lists them.
            let supportsEnvironments = cloud.configuration.linkSource == .appServer
            let environments = supportsEnvironments ? await cloud.appServerEnvironmentOptions() : []
            guard let plan = try await wizard.choosePlan(availability: availability,
                scopeIsCurrent: { cloud.auth.user?.id == userID && cloud.auth.teamID == teamID },
                supportsRepository: cloud.configuration.linkSource == .legacy,
                environments: environments, supportsEnvironments: supportsEnvironments, present: present) else { return }
            var request = plan.request
            if let new = plan.newEnvironment {
                // Saved first, then booted: the first machine starts cold and runs the setup itself.
                guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                request.environment = try await cloud.appServerSaveEnvironment(new)
            }
            request.script = try await request.loadScript(work: services.work)
            try Task.checkCancellation()
            guard cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
            let creation = CloudHandlers.creationFlow(context, startedByPerson: true, askedBy: askedBy, proceed: { creation in
                try CloudHandlers.checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                       currentUserID: cloud.auth.user?.id, currentTeamID: cloud.auth.teamID)
            }).start(in: window, existing: nil, request: request)
            // Failed attempts remain listed for Retry. Only readiness, explicit dismissal,
            // teardown, cancellation, or an account change ends this observation.
            for await (readiness, currentUser, currentTeam) in ObservationStream({
                (CloudHandlers.workspaceSetupReadiness(creation, in: cloud.creations), cloud.auth.user?.id, cloud.auth.teamID)
            }) {
                do {
                    try CloudHandlers.checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                           currentUserID: currentUser, currentTeamID: currentTeam)
                } catch is CancellationError { return }
                guard readiness != .ended else { return }
                if readiness == .ready { break }
            }
            guard !creation.isTornDown, let session = creation.session else { return }
            try Task.checkCancellation()
            if plan.repository != nil {
                // The completion task outlives the progress row. Account changes wake this observer;
                // the bootstrap's bounded completion result ends it on success or failure.
                for await (progress, currentUser, currentTeam) in ObservationStream({
                    (CloudHandlers.workspaceSetupCompletion(creation), cloud.auth.user?.id, cloud.auth.teamID)
                }) {
                    do {
                        try CloudHandlers.checkCreationScope(creation, in: cloud.creations, expectedUserID: userID, expectedTeamID: teamID,
                                               currentUserID: currentUser, currentTeamID: currentTeam)
                    } catch is CancellationError { return }
                    guard !progress.ended else { return }
                    guard let completion = progress.completion else { continue }
                    try Task.checkCancellation()
                    guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                    let scope: CmuxDialogScope = window.flatMap { services.windows.controller(for: $0.id)?.window }.map(CmuxDialogScope.window) ?? .app
                    let machine = CloudMachineBootstrap.Machine(api: cloud.api.pinningTeam(teamID), machineID: session.machineID)
                    let recovered: CloudMachineBootstrap.Completion
                    if let repo = plan.repository {
                        recovered = try await connector.recover(completion, repo: repo, on: machine, in: scope)
                    } else { recovered = completion }
                    try Task.checkCancellation()
                    guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                    try await wizard.finishBootstrap(recovered) { path in
                        let filing = ActionRunScope.carrying(ActionRunScope(origin: .user, allowsViewChange: false)) {
                            // task-owner: this awaited filing; cancellation below ends its task
                            Task { await services.windows.createWorkspace(cwd: path, on: session.daemon, into: window?.id) }
                        }
                        let id = await withTaskCancellationHandler { await filing.value } onCancel: { filing.cancel() }
                        guard let id else {
                            throw ActionFailure(message: CloudStrings.notConnected)
                        }
                        try Task.checkCancellation()
                        guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
                        if CloudWorkspaceSetupWizard.shouldRevealProject(originalWorkspace: creation.workspaceID,
                            currentWorkspace: window?.workspaceID, windowIsActive: services.windows.active?.state.id == window?.id) {
                            CloudHandlers.show(id, context)
                        }
                    }
                    break
                }
            }
            try Task.checkCancellation()
            guard !creation.isTornDown, availability == .available, let userID,
                  cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else { return }
            try await wizard.offerCredentialSetup(machine: session.machine.title,
                account: cloud.auth.activeTeam.team?.displayName ?? CloudWorkspaceSetupWizard.personalAccountTitle, present: present) { provider in
                try Task.checkCancellation()
                guard !creation.isTornDown, cloud.auth.user?.id == userID, cloud.auth.teamID == teamID else {
                    throw CancellationError()
                }
                if provider == .codex {
                    guard let windowID = window?.id, let originalWindow = services.windows.controller(for: windowID)?.window else {
                        throw CancellationError()
                    }
                    try await cloud.codexBroker.run(machineID: session.machineID,
                        scope: .init(userID: userID, teamID: teamID), confirmed: true,
                        presentDeviceCode: { prompt in
                            await CloudPresenter.presentCodexDeviceCode(prompt, in: .window(originalWindow))
                        })
                    return
                }
                let transfer = CloudCredentialTransfer(provider: .claude,
                    machineID: session.machineID, teamID: teamID, userID: userID, openTerminal: { [weak services] line in
                        await services?.openLocalProviderLogin(line) ?? false
                    })
                try await transfer.run(api: cloud.api, currentTeamID: { cloud.auth.teamID },
                                       currentUserID: { cloud.auth.user?.id }, confirmed: true)
            }
        }
    }

}
