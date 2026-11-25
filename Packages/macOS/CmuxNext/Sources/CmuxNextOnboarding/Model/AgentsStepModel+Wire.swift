import CmuxNextWindowRules

/// What the Rust Agents step rules read and answer (`onboarding_steps_agents`,
/// `onboarding_steps_agents_table`): the app's types as cmux-window-rules `onboarding_steps` names
/// them. No rule lives here.
extension AgentsStepModel {
    /// The last read and what the person did here (Rust `AgentsFacts`).
    nonisolated struct Facts: Encodable, Sendable {
        nonisolated struct Agent: Encodable, Sendable {
            var id: String, auth: String, installed: Bool
            @MainActor init(_ agent: OnboardingAgent) {
                id = agent.id
                auth = agent.auth.rawValue
                installed = agent.installed
            }
        }

        var agents: [Agent]
        var signingIn: String?
        var installAwaitingRead: String?
        var loginsOpened: [String] = []
        var confirmedLogins: [String] = []
        var installing = false
    }

    /// What the step lists from a read (Rust `AgentsView`).
    nonisolated struct View: Decodable, Sendable {
        nonisolated struct Marks: Decodable, Sendable {
            var offersSignIn: Bool, countsAsSignedIn: Bool, awaitsConfirmation: Bool, canInstall: Bool
        }

        nonisolated struct FinishInstall: Decodable, Sendable { var kind: String, message: String? }

        var listed: [Int]
        var installable: [Int]
        var marks: [Marks]
        var signedInNow: Bool
        var finishInstall: FinishInstall?
    }

    /// The step's fixed table: the vendors' install pages and the refusal texts.
    nonisolated struct Table: Decodable, Sendable {
        var installPages: [String: String]
        var installedNotFound: String
        var noAgentsService: String

        /// Asked once; an FFI pin without the op has no install pages and empty texts.
        static let shared = WindowRules().call("onboarding_steps_agents_table", Empty(), as: Table.self)
            ?? Table(installPages: [:], installedNotFound: "", noAgentsService: "")
    }

    nonisolated struct Empty: Encodable, Sendable {}

    /// The rules' answer for `agents`, nil when the pinned FFI lacks the op.
    static func ask(_ facts: Facts) -> View? {
        WindowRules().call("onboarding_steps_agents", facts, as: View.self)
    }
}

extension OnboardingAgent {
    /// One agent's marks with nothing done here yet (``offersSignIn``).
    var marks: AgentsStepModel.View.Marks? {
        AgentsStepModel.ask(AgentsStepModel.Facts(agents: [.init(self)]))?.marks.first
    }
}
