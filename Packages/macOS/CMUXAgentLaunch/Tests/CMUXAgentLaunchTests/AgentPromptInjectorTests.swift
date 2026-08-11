import CMUXAgentLaunch
import Testing

@Suite
@MainActor
struct AgentPromptInjectorTests {
    @Test
    func submitClearsComposerBeforeTypingAndSubmitting() {
        let writer = RecordingAgentTerminalInputWriter()

        let result = AgentPromptInjector().submit(
            text: "Reply with a numbered list",
            submitKey: "return",
            writer: writer
        )

        #expect(result == .accepted)
        #expect(writer.operations == [
            .key("ctrl+a"),
            .key("ctrl+k"),
            .key("ctrl+u"),
            .text("Reply with a numbered list"),
            .key("return"),
        ])
    }
}

@MainActor
private final class RecordingAgentTerminalInputWriter: AgentTerminalInputWriting {
    enum Operation: Equatable {
        case key(String)
        case text(String)
    }

    var operations: [Operation] = []

    func sendNamedKey(_ keyName: String) -> AgentLaunchExecutionResult {
        operations.append(.key(keyName))
        return .accepted
    }

    func sendText(_ text: String) -> AgentLaunchExecutionResult {
        operations.append(.text(text))
        return .accepted
    }
}
