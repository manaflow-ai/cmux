import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextCLIInstall
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextOnboarding

extension HomeHostView {
    /// A Chief's Set Up cmux card (``SetupCardHost``) in the form ``FirstRunSetup/cardForm`` names (a first run's whole
    /// card, or its Chief form while Chief's agent is missing or signed out), under the pinned section; none elsewhere.
    func watchSetupCard() {
        setupCardWatch?.cancel()
        setupCardWatch = nil
        guard isChief else { return showSetupCard(nil) }
        let onboarding = control.services.onboarding, setup = onboarding.setup, meetChief = onboarding.chief
        setup.checkChiefAgent(source: onboarding.signInHarnesses)
        // task-owner: lives as long as this view is a Chief's; event-driven (Observation of FirstRunSetup; Meet Chief holds it).
        setupCardWatch = Task { [weak self] in
            for await form in ObservationStream({ meetChief.holdsWelcome ? nil : setup.cardForm }) {
                guard !Task.isCancelled else { return }
                self?.showSetupCard(form)
            }
        }
    }

    private func showSetupCard(_ form: FirstRunSetup.CardForm?) {
        if let card = setupCard, card.form != form { card.close(); setupCard = nil; transcript.setSetupCard(nil, height: 0) }
        guard let form else { return }
        let services = control.services, auth = control.services.cloud.auth, registry = control.services.registry
        let environment = SetupCardEnvironment(
            account: { (auth.isSignedIn, auth.user?.primaryEmail) },
            signInAccount: { _ = registry.perform("palette.auth.signIn", invocation: ActionInvocation(origin: .user)) },
            cliState: { CLIInstallReport.setupRow(await CLIInstallHandlers.pathCheck(CLIPathInstaller().source)) },
            installCLI: { await CLIInstallHandlers.install(.cmux, replacing: $0, in: NSApp.keyWindow) },
            openAgents: { [weak services] in services?.onboarding.show(step: .agents) },
            look: SetupCardLook(design: .shared) { [weak services] in services?.settings }, signInBackend: services.cloud.configuration.signInBackendLine)
        guard setupCard == nil, let card = SetupCardHost(setup: services.onboarding.setup, agents: services.onboarding.signInHarnesses,
                                                         environment: environment, overlayProcess: services.overlayProcess,
                                                         form: form) else { return }
        setupCard = card
        card.onHeightChange = { [weak self, weak card] in
            guard let self, let card, card === self.setupCard else { return }
            self.transcript.setSetupCard(card.page, height: card.height)
        }
        transcript.setSetupCard(card.page, height: 0)
    }
}
