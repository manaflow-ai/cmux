import AppKit
import OSLog
import SwiftUI

/// Binds the Cloud sidebar to its app-authenticated CodeRouter operations.
extension MachinesPanelView {
    private static let coderouterLogger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")

    /// The team and signed-in account whose CodeRouter rows are shown.
    var currentCoderouterScope: CoderouterAccountScope? {
        CoderouterAccountScope(teamID: accountFlow?.confirmedTeamID, identityID: accountFlow?.currentIdentity?.id)
    }

    var coderouter: CloudTreeCoderouterSection {
        CloudTreeCoderouterSection(
            accounts: coderouterStore.state.accounts,
            isRefreshing: coderouterStore.isRefreshing || coderouterStore.state.isLoadingScope,
            failure: coderouterStore.state.failure
        )
    }

    @MainActor
    func refreshCoderouterAccounts() async {
        coderouterStore.state.select(currentCoderouterScope)
        guard let scope = currentCoderouterScope else { return }
        guard let readRevision = coderouterStore.state.beginRefresh(for: scope) else { return }
        do {
            let teamName = accountFlow?.availableTeams.first(where: { $0.id == scope.teamID })?.displayName
            Self.coderouterLogger.info("Refreshing CodeRouter accounts for cmux team ID \(scope.teamID, privacy: .public), name \(teamName ?? "<nil>", privacy: .public)")
            let snapshot = try await withCoderouterAppSession(scope: scope, teamName: teamName) { run in
                try await CoderouterCLIAccountReader.snapshot(for: scope.teamID, name: teamName, run: run)
            }
            // A team or identity switch can finish while the CLI is running.
            guard !Task.isCancelled, currentCoderouterScope == scope else { return }
            coderouterStore.state.apply(
                accounts: snapshot.accounts,
                organizationID: snapshot.organizationID,
                for: scope,
                startedAt: readRevision
            )
        } catch is CancellationError {
            return
        } catch {
            let failure = CoderouterCLIFailure.classify(error)
            Self.coderouterLogger.error("CodeRouter account refresh failed (\(String(describing: failure), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            // Never let an old scope's failure clear or authorize a replacement,
            // and let a session mid-revalidation retry on the next tick.
            guard !Task.isCancelled, currentCoderouterScope == scope, failure != .sessionChanging else { return }
            // Same-team rows remain useful during a transient error, but the
            // add destination is withdrawn until a fresh read succeeds.
            coderouterStore.state.fail(failure, for: scope, startedAt: readRevision)
        }
    }

    /// Runs CodeRouter CLI commands as the account signed into this app, in a
    /// private CLI configuration, never the CLI's own saved sign-in.
    private func withCoderouterAppSession<T>(
        scope: CoderouterAccountScope,
        teamName: String?,
        body: (CoderouterCLIAccountReader.Run) async throws -> T
    ) async throws -> T {
        guard let session = coderouterAppSession() else {
            throw CoderouterCLIFailure.signInRequired
        }
        return try await session.withSession(
            teamID: scope.teamID,
            teamName: teamName,
            expectedAccountID: scope.identityID,
            body: body
        )
    }

    /// The CLI session for this app's sign-in, built per operation because
    /// the auth coordinator and the resolved CLI can change while the panel
    /// is open. Nil when the app has no auth coordinator.
    @MainActor
    private func coderouterAppSession() -> CoderouterAppCLISession? {
        guard let coordinator = AppDelegate.shared?.auth?.coordinator else { return nil }
        return CoderouterAppCLISession(
            credentials: CoderouterAppCredentialSource(auth: coordinator),
            executable: CoderouterCLIAccountReader.resolvedExecutable()
        )
    }

    @MainActor
    func removeCoderouterAccount(_ account: CloudTreeNode.CoderouterAccount) {
        // The row may be stale while a team change is settling. Never redirect
        // its removal to whichever team is selected now.
        guard let scope = coderouterStore.state.removalScope(selected: currentCoderouterScope) else { return }
        let teamName = accountFlow?.availableTeams.first(where: { $0.id == scope.teamID })?.displayName
        guard CloudTreeNodeActions.confirmDestructive(
            title: String(format: String(localized: "coderouter.removeAccount.title", defaultValue: "Remove \u{201C}%@\u{201D} from coderouter?"), account.title),
            message: String(localized: "coderouter.removeAccount.message", defaultValue: "The team stops routing agents through this account. You can add it again later."),
            verb: String(localized: "coderouter.removeAccount.verb", defaultValue: "Remove")
        ) else { return }
        // Confirmation is modal; the selection may have changed while it was
        // displayed.
        guard coderouterStore.state.removalScope(selected: currentCoderouterScope) == scope,
              let previousIndex = coderouterStore.state.removeOptimistically(accountID: account.id, for: scope) else { return }
        Task { @MainActor in
            await coderouterStore.lane.run {
                do {
                    try await withCoderouterAppSession(scope: scope, teamName: teamName) { run in
                        try await CoderouterCLIAccountReader.remove(
                            accountID: account.id,
                            for: scope.teamID,
                            name: teamName,
                            run: run
                        )
                    }
                    coderouterStore.state.finishRemoval(accountID: account.id, for: scope)
                } catch {
                    let failure = CoderouterCLIFailure.classify(error)
                    Self.coderouterLogger.error("CodeRouter account removal failed (\(String(describing: failure), privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    coderouterStore.state.restore(account, at: previousIndex, for: scope)
                    viewModel.noteTreeHint(failure.removalMessage)
                }
            }
            requestCoderouterRefresh()
        }
    }

    /// Restarts the refresh loop now; the loop clears the spinner after its read.
    @MainActor
    func requestCoderouterRefresh() {
        guard !coderouterStore.isRefreshing else { return }
        if let scope = currentCoderouterScope { coderouterStore.state.invalidateDestination(for: scope) }
        coderouterStore.isRefreshing = true
        coderouterStore.refreshRequest += 1
    }

    @MainActor
    func addCoderouterAccount(_ provider: CoderouterProvider) {
        guard let scope = currentCoderouterScope else {
            viewModel.noteTreeHint(String(localized: "teamMembers.error.noTeam", defaultValue: "Select a team first."))
            return
        }
        let destination: CoderouterAccountDestination
        switch coderouterStore.state.addAvailability(for: scope) {
        case .ready(let ready):
            destination = ready
        case .loading:
            viewModel.noteTreeHint(String(localized: "coderouter.loadingTeam", defaultValue: "Account settings are still loading for this team. Try again in a moment."))
            requestCoderouterRefresh()
            return
        case .failed(let failure):
            // Say what is wrong; the retry may already fix a transient failure.
            viewModel.noteTreeHint(failure.message)
            requestCoderouterRefresh()
            return
        }
        // The terminal runs the CLI directly, as this app's account: `cmux cr`
        // or a login shell's `cr` would use the CLI's own saved sign-in.
        guard let session = coderouterAppSession() else {
            viewModel.noteTreeHint(CoderouterCLIFailure.signInRequired.message)
            return
        }
        guard session.executable != nil else {
            viewModel.noteTreeHint(CoderouterCLIFailure.notInstalled.message)
            return
        }
        let teamName = accountFlow?.availableTeams.first(where: { $0.id == scope.teamID })?.displayName
        coderouterStore.startAddTask { @MainActor addGeneration in
            guard coderouterStore.isCurrentAddTask(addGeneration) else { return }
            let sessionDirectory: URL
            do {
                await CoderouterAppCLISession.sweepAllStaleSessionsOffMainActor(base: session.baseDirectory)
                try Task.checkCancellation()
                let credentials = try await session.credentials.credentials(expectedAccountID: scope.identityID)
                // A refresh can replace or withdraw the destination while the
                // session resolves; never launch setup for a stale one.
                guard coderouterStore.isCurrentAddTask(addGeneration), currentCoderouterScope == scope else { return }
                switch coderouterStore.state.addAvailability(for: scope) {
                case .ready(let current) where current.organizationID == destination.organizationID:
                    break
                case .failed(let failure):
                    viewModel.noteTreeHint(failure.message)
                    requestCoderouterRefresh()
                    return
                case .ready, .loading:
                    viewModel.noteTreeHint(String(localized: "coderouter.loadingTeam", defaultValue: "Account settings are still loading for this team. Try again in a moment."))
                    requestCoderouterRefresh()
                    return
                }
                sessionDirectory = try session.makeSessionDirectory(
                    kind: CoderouterAppCLISession.addSession,
                    credentials: credentials,
                    teamID: scope.teamID,
                    teamName: teamName
                )
            } catch {
                guard coderouterStore.isCurrentAddTask(addGeneration), currentCoderouterScope == scope else { return }
                viewModel.noteTreeHint(CoderouterCLIFailure.classify(error).addMessage)
                return
            }
            // The terminal's shell deletes the directory when `add` exits. Any
            // path below that never starts the terminal deletes it here.
            var launched = false
            defer {
                if !launched { try? FileManager.default.removeItem(at: sessionDirectory) }
            }
            let command: String
            do {
                command = try session.addAccountCommand(
                    provider: provider,
                    organizationID: destination.organizationID,
                    sessionDirectory: sessionDirectory
                )
            } catch {
                viewModel.noteTreeHint(CoderouterCLIFailure.classify(error).addMessage)
                return
            }
            let coordinator = CoderouterSetupWorkspaceCoordinator(
                managerSource: { @MainActor in
                    if let tabManager, !tabManager.isFinalizedForWindowClose {
                        return tabManager
                    }
                    if let active = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: nil),
                       !active.isFinalizedForWindowClose {
                        return active
                    }
                    return AppDelegate.shared?.tabManager.flatMap { manager in
                        manager.isFinalizedForWindowClose ? nil : manager
                    }
                },
                provider: provider,
                initialTerminalCommand: command
            )
            guard coderouterStore.isCurrentAddTask(addGeneration), currentCoderouterScope == scope else { return }
            guard let route = coordinator.resolveDestination() else {
                viewModel.noteTreeHint(String(
                    localized: "coderouter.setup.localWorkspaceUnavailable",
                    defaultValue: "Could not open a local workspace for CodeRouter setup."
                ))
                return
            }

            // A newly-created setup workspace already owns the initial command
            // in its starter terminal. Reuse adds a fresh terminal in the
            // persisted workspace so each provider gets its own interactive
            // setup session.
            let workspace: Workspace
            switch route {
            case .created:
                launched = true
                return
            case let .existing(existingWorkspace, _):
                workspace = existingWorkspace
            }

            do {
                guard coderouterStore.isCurrentAddTask(addGeneration), currentCoderouterScope == scope else { return }
                try coordinator.launchAccountTerminal(in: workspace.id)
                launched = true
            } catch {
                viewModel.noteTreeFailure(error.localizedDescription)
            }
        }
    }
}
