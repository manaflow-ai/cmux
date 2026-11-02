import AppIntents
import CmuxMobileModel

/// New Agent Chat from Shortcuts, Siri, Spotlight or the Action Button: the phone's form of
/// the Mac's Start Agent from Any App (its quick composer). It opens cmux into a new agent
/// chat on the Mac new workspaces go to, in its most recent folder, with the message (if
/// any) in the composer, ready to send.
struct NewAgentChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Agent Chat"
    static let description = IntentDescription("Opens cmux and starts a new agent chat on your computer, with your message ready to send.")
    static let openAppWhenRun = true

    @Parameter(title: "Message", requestValueDialog: "What should the agent do?")
    var message: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New agent chat with \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AgentChatLauncher.shared.start(prompt: message)
        return .result()
    }
}
