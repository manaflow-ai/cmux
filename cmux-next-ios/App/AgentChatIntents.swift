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

#if DEBUG
extension NewAgentChatIntent {
    @MainActor private static var ranFromLaunchArguments = false

    @MainActor
    static func runFromLaunchArguments() async {
        guard !ranFromLaunchArguments else { return }
        ranFromLaunchArguments = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-cmux-mobile-run-intent"), arguments.indices.contains(index + 1) else { return }
        let message = ProcessInfo.processInfo.environment["CMUX_MOBILE_INTENT_MESSAGE"]
        switch arguments[index + 1] {
        case "new-agent-chat":
            var intent = NewAgentChatIntent()
            intent.message = message
            _ = try? await intent.perform()
        case "message-chief":
            var intent = MessageChiefIntent()
            intent.message = message
            _ = try? await intent.perform()
        default:
            return
        }
    }
}
#endif
