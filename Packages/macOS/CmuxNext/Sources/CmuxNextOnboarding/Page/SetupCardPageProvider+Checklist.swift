import CmuxNextSettings
import Foundation

/// The sidebar's native "Finish setting up" card (Lawrence msg 25425): the rows the Set Up cmux page drew
/// (setupModel.ts `setupSteps`), as ``SetupChecklistStep`` values, and the click that runs one. A click in the
/// sidebar is the person's own, so it needs none of the page's gesture checks.
extension SetupCardPageProvider {
    /// The card's title, x label and "1 of N".
    public static var checklistTitle: String { OnboardingStrings.setupTitle }
    public static var checklistHideLabel: String { OnboardingStrings.setupHide }
    public static func checklistProgress(_ done: Int, of total: Int) -> String { OnboardingStrings.setupProgress(done, total) }

    /// The rows in their order: agents, the chat history (when this Mac has chats), the account, the command line.
    public var checklist: [SetupChecklistStep] {
        var steps = [agentsStep]
        if history == true {
            steps.append(SetupChecklistStep(kind: .history, title: OnboardingStrings.setupHistory, done: setup.historyDone,
                                            help: OnboardingStrings.setupHistoryDetail))
        }
        let account = environment.account()
        steps.append(SetupChecklistStep(kind: .account, title: OnboardingStrings.setupSignInTo("cmux"), done: account.signedIn,
                                        help: account.signedIn ? account.email : OnboardingStrings.setupAccountDetail))
        let cli = cliInstalling ? "installing" : self.cli ?? "missing"
        steps.append(SetupChecklistStep(
            kind: .cli, title: cli == "other" ? OnboardingStrings.setupCLIReplace : OnboardingStrings.setupCLI, done: cli == "installed",
            busy: cli == "installing", runnable: cli == "missing" || cli == "other",
            help: switch cli {
            case "other": OnboardingStrings.setupCLIOther
            case "foreign": OnboardingStrings.setupCLIForeign
            case "fromImage": OnboardingStrings.setupCLIFromImage
            default: OnboardingStrings.setupCLIDetail
            }))
        return steps
    }

    /// The agents row: done once one agent is signed in; else the agent closest to answering (signed in, a login
    /// to confirm, signed out, installing, failed, missing) is the one its click installs or signs in.
    private var agentsStep: SetupChecklistStep {
        let rows = agentRows
        let rank = ["signedIn": 0, "unverified": 1, "signedOut": 2, "installing": 3, "failed": 4, "missing": 5]
        let lead = rows.min { rank[$0.state, default: 9] < rank[$1.state, default: 9] }
        guard let lead else { return SetupChecklistStep(kind: .agents, title: OnboardingStrings.setupInstallAgent("Claude Code"), done: false, runnable: false) }
        let signsIn = ["signedIn", "unverified", "signedOut"].contains(lead.state)
        let title = signsIn ? OnboardingStrings.setupSignInTo(lead.name) : OnboardingStrings.setupInstallAgent(lead.name)
        return switch lead.state {
        case "signedIn": SetupChecklistStep(kind: .agents, title: title, done: true)
        case "unverified": SetupChecklistStep(kind: .agents, title: title, actionTitle: OnboardingStrings.setupConfirmSignedIn, done: false,
                                              help: OnboardingStrings.setupAgentUnverified(lead.name))
        case "installing": SetupChecklistStep(kind: .agents, title: title, done: false, busy: true)
        case "failed": SetupChecklistStep(kind: .agents, title: title, done: false, help: OnboardingStrings.setupAgentFailed(lead.name))
        default: SetupChecklistStep(kind: .agents, title: title, done: false)
        }
    }

    /// Runs `kind`'s step, as its row's or the button's click: the same actions the page's buttons ran.
    public func perform(_ kind: SetupChecklistStep.Kind) {
        guard let step = checklist.first(where: { $0.kind == kind }), step.canRun else { return }
        let action: JSONValue
        switch kind {
        case .agents:
            let rank = ["unverified": 1, "signedOut": 2, "installing": 3, "failed": 4, "missing": 5]
            guard let lead = agentRows.min(by: { rank[$0.state, default: 9] < rank[$1.state, default: 9] }) else { return }
            let verb = switch lead.state {
            case "unverified": "confirmAgent"
            case "signedOut": "signInAgent"
            default: "installAgent"
            }
            action = ["kind": .string(verb), "id": .string(lead.id)]
        case .history: action = ["kind": "importHistory"]
        case .account: action = ["kind": "signInAccount"]
        case .cli: action = ["kind": "installCLI"]
        }
        try? run(action)
    }

    /// Reads the agents' sign-ins and the `cmux` on PATH again (cmux came back to the front after a sign-in).
    public func refresh() {
        agents.refresh(recheck: true)
        readCLI()
    }

    /// Every row is done: the card ends (``FirstRunSetup/end()``).
    public var isComplete: Bool { allDone }
}
