import Testing
@testable import CmuxCommandPalette

struct CommandPaletteArgumentCollectionTests {
    @Test
    func collectsDeclaredChoicesInOrder() throws {
        let arguments = [
            CommandPaletteChoiceArgument(
                name: "harness",
                title: "Harness",
                choices: [.init(value: "claude", title: "Claude Code")]
            ),
            CommandPaletteChoiceArgument(
                name: "destination",
                title: "Destination",
                choices: [.init(value: "right", title: "Right Split")]
            ),
        ]
        var collection = try #require(CommandPaletteArgumentCollection(
            commandID: "fork",
            arguments: arguments
        ))

        #expect(collection.selectCurrentChoice(value: "claude") == .advanced)
        #expect(collection.currentArgument.name == "destination")
        #expect(collection.selectCurrentChoice(value: "right") == .completed)
        #expect(collection.values == ["harness": "claude", "destination": "right"])
    }

    @Test
    func rejectsUndeclaredValue() throws {
        var collection = try #require(CommandPaletteArgumentCollection(
            commandID: "fork",
            arguments: [
                CommandPaletteChoiceArgument(
                    name: "harness",
                    title: "Harness",
                    choices: [.init(value: "codex", title: "Codex")]
                ),
            ]
        ))

        #expect(collection.selectCurrentChoice(value: "unknown") == .invalid)
        #expect(collection.values.isEmpty)
    }

    @Test
    func fullyCollectedArgumentsDoNotRestartTheFlow() {
        let collection = CommandPaletteArgumentCollection(
            commandID: "fork",
            arguments: [
                CommandPaletteChoiceArgument(
                    name: "harness",
                    title: "Harness",
                    choices: [.init(value: "codex", title: "Codex")]
                ),
            ],
            initialValues: ["harness": "codex"]
        )

        #expect(collection == nil)
    }

    @Test
    func invalidInitialChoiceIsCollectedAgain() throws {
        let arguments = [
            CommandPaletteChoiceArgument(
                name: "harness",
                title: "Harness",
                choices: [.init(value: "claude", title: "Claude Code")]
            ),
            CommandPaletteChoiceArgument(
                name: "destination",
                title: "Destination",
                choices: [.init(value: "right", title: "Right Split")]
            ),
        ]
        var collection = try #require(CommandPaletteArgumentCollection(
            commandID: "fork",
            arguments: arguments,
            initialValues: [
                "harness": "outside-declared-choices",
                "destination": "also-outside-declared-choices",
            ]
        ))

        #expect(collection.currentArgument.name == "harness")
        #expect(collection.values.isEmpty)
        #expect(collection.selectCurrentChoice(value: "claude") == .advanced)
        #expect(collection.currentArgument.name == "destination")
        #expect(collection.selectCurrentChoice(value: "right") == .completed)
        #expect(collection.values == ["harness": "claude", "destination": "right"])
    }
}
