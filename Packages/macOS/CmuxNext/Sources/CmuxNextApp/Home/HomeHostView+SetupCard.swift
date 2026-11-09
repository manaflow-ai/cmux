import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextCLIInstall
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextHome
import CmuxNextOnboarding

extension HomeHostView {
    /// A Chief's Set Up cmux card (``SetupCardHost``) while ``FirstRunSetup`` shows it (a first run, until Hide or
    /// every row done), under the pinned section; none for any other conversation. Made only while it shows.
    func watchSetupCard() {
        setupCardWatch?.cancel()
        setupCardWatch = nil
        guard isChief else { return showSetupCard(false) }
        let setup = control.services.onboarding.setup
        // task-owner: lives as long as this view is a Chief's; event-driven (Observation of FirstRunSetup).
        setupCardWatch = Task { [weak self] in
            for await shows in ObservationStream({ setup.shows }) {
                guard !Task.isCancelled else { return }
                self?.showSetupCard(shows)
            }
        }
    }

    private func showSetupCard(_ shows: Bool) {
        guard shows else {
            setupCard?.close()
            setupCard = nil
            return transcript.setSetupCard(nil, height: 0)
        }
        let services = control.services, auth = control.services.cloud.auth, registry = control.services.registry
        let environment = SetupCardEnvironment(
            account: { (auth.isSignedIn, auth.user?.primaryEmail) },
            signInAccount: { _ = registry.perform("palette.auth.signIn", invocation: ActionInvocation(origin: .user)) },
            cliState: {
                switch await CLIInstallHandlers.pathCheck(CLIPathInstaller().source).status {
                case .thisApp: "installed"
                case .otherApp, .foreign: "other"
                case .missing, .dangling: "missing"
                }
            },
            installCLI: { await CLIInstallHandlers.install(.cmux, replacing: $0, in: NSApp.keyWindow) },
            openAgents: { [weak services] in services?.onboarding.show(step: .agents) })
        guard setupCard == nil, let card = SetupCardHost(setup: services.onboarding.setup, agents: services.onboarding.signInHarnesses,
                                                         environment: environment, overlayProcess: services.overlayProcess) else { return }
        setupCard = card
        card.onHeightChange = { [weak self, weak card] in
            guard let self, let card, card === self.setupCard else { return }
            self.transcript.setSetupCard(card.page, height: card.height)
        }
        transcript.setSetupCard(card.page, height: 0)
    }
}
