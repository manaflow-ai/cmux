import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// An agent-chat action that can't run says why in its own words: its title and its cause, never
/// Dictation's reason (a capture's Continue After Error came back "Dictation works in agent chats").
@MainActor @Suite(.serialized)
struct AgentChatRefusalReasonTests {
    nonisolated static let chatActions: [ActionID] = [
        "agentPane.toggleDisplaySettings", "agentPane.replayConversation", "agentPane.editInstructions",
        "agentPane.addProjectFiles", "agentPane.markUnread", "agentPane.moveToFloatingChat",
        "agentPane.continueAfterError", "agentPane.toggleMinimap", "agentPane.revealCwdInFinder",
        "agentPane.openCwdInTerminal", "agentPane.createCheckpoint", "agentPane.setModel",
    ]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))
        AppActions.bind(services)
        return services
    }

    /// A person's run with an agent chat's key context, but no chat in any pane.
    static func noChatRun() -> ActionInvocation {
        var invocation = ActionInvocation(arguments: ["model": .string("opus")], origin: .user)
        // Create Checkpoint also needs a checkpoint to be capturable, or the registry turns it away first.
        invocation.keyContext = [.agentPaneFocused, .checkpointCaptureAvailable]
        return invocation
    }

    @Test(arguments: chatActions)
    func aChatActionWithNoChatNamesItselfNotDictation(_ id: ActionID) throws {
        let services = Self.services()
        let title = try #require(services.registry.descriptor(for: id)?.title)
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: Self.noChatRun())
        }
        let reason = try #require(refusal, "\(id) ran with no chat")
        #expect(reason != MiscHandlerStrings.noAgentChat, "\(id) refused with Dictation's reason")
        // With no pane at all, a tab action's "No pane is focused." is the honest reason too.
        #expect(reason.contains(title) || reason == MiscHandlerStrings.noPane, "\(id): \"\(reason)\" does not name \(title)")
    }

    /// Dictation's refusal is its own: it never takes a chat action's words.
    @Test func dictationKeepsItsOwnReason() {
        let services = Self.services()
        let reason = services.registry.capturingRefusal {
            _ = services.registry.perform("palette.toggleDictation", invocation: Self.noChatRun())
        } ?? ""
        let borrowed = Self.chatActions.compactMap { services.registry.descriptor(for: $0)?.title }.filter { reason.contains($0) }
        #expect(borrowed.isEmpty, "Dictation refused with \"\(reason)\"")
    }
}
