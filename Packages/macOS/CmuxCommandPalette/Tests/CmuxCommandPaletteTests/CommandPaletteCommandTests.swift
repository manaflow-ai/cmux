import Testing

@testable import CmuxCommandPalette

struct CommandPaletteCommandTests {
    @Test
    func runDeliversCollectedArgumentsThroughTheOnlyExecutionAPI() {
        var receivedArguments: [String: String] = [:]
        let command = CommandPaletteCommand(
            id: "test.arguments",
            rank: 0,
            title: "Arguments",
            subtitle: "Test",
            shortcutHint: nil,
            kindLabel: nil,
            keywords: [],
            dismissOnRun: true,
            choiceArguments: [],
            argumentAction: { receivedArguments = $0 }
        )

        command.run(arguments: ["harness": "opencode"])

        #expect(receivedArguments == ["harness": "opencode"])
    }
}
