import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("Cmux action registry")
struct CmuxActionRegistryTests {
    @Test func automationRequiresStaticallyDeclaredArguments() {
        var didRun = false
        let command = makeCommand(arguments: [
            CmuxActionArgumentDefinition(name: "name", allowsEmpty: true),
        ]) { _ in
            didRun = true
            return .completed
        }

        #expect(command.execute(CmuxActionInvocation(source: .automation)) == .requiresArguments([
            CmuxActionArgumentDefinition(name: "name", allowsEmpty: true),
        ]))
        #expect(!didRun)
    }

    @Test func paletteMayCollectMissingArgumentsInteractively() {
        let command = makeCommand(arguments: [
            CmuxActionArgumentDefinition(name: "name"),
        ]) { invocation in
            #expect(invocation.arguments.isEmpty)
            return .presented
        }

        #expect(command.execute(CmuxActionInvocation(source: .commandPalette)) == .presented)
    }

    @Test func automationForwardsDeclaredArgumentsIncludingEmptyValues() {
        var received: CmuxActionInvocation?
        let command = makeCommand(arguments: [
            CmuxActionArgumentDefinition(name: "name", allowsEmpty: true),
        ]) { invocation in
            received = invocation
            return .completed
        }
        let invocation = CmuxActionInvocation(
            source: .automation,
            arguments: ["name": ""]
        )

        #expect(command.execute(invocation) == .completed)
        #expect(received == invocation)
    }

    @Test func undeclaredArgumentsAreRejectedBeforeExecution() {
        var didRun = false
        let command = makeCommand { _ in
            didRun = true
            return .completed
        }

        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["surprise": "value"]
        )) == .invalidArguments(["surprise"]))
        #expect(!didRun)
    }

    @Test func pathArgumentsResolveRelativeToTheAutomationCaller() {
        var receivedPath: String?
        let command = makeCommand(arguments: [
            CmuxActionArgumentDefinition(name: "path", valueType: .path),
        ]) { invocation in
            receivedPath = invocation.string("path")
            return .completed
        }

        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": "Sources/../Tests"],
            workingDirectory: "/tmp/cmux-project"
        )) == .completed)
        #expect(receivedPath == "/tmp/cmux-project/Tests")
    }

    @Test func booleanArgumentsAreValidatedAndCoercedCentrally() {
        var receivedOverwrite: Bool?
        let command = makeCommand(arguments: [
            CmuxActionArgumentDefinition(
                name: "overwrite",
                valueType: .boolean,
                required: false
            ),
        ]) { invocation in
            receivedOverwrite = invocation.bool("overwrite")
            return .completed
        }

        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["overwrite": "yes"]
        )) == .completed)
        #expect(receivedOverwrite == true)
        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["overwrite": "sometimes"]
        )) == .invalidArgumentValues(["overwrite"]))
        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["overwrite": ""]
        )) == .invalidArgumentValues(["overwrite"]))
    }

    @Test func finiteChoiceArgumentsRejectUndeclaredValues() {
        var receivedHarness: String?
        let command = makeCommand(arguments: [
            CmuxActionArgumentDefinition(
                name: "harness",
                title: "Harness",
                choices: [
                    .init(value: "claude", title: "Claude Code"),
                    .init(value: "codex", title: "Codex"),
                ]
            ),
        ]) { invocation in
            receivedHarness = invocation.string("harness")
            return .completed
        }

        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["harness": "unknown"]
        )) == .invalidArgumentValues(["harness"]))
        #expect(receivedHarness == nil)
        #expect(command.execute(CmuxActionInvocation(
            source: .automation,
            arguments: ["harness": "claude"]
        )) == .completed)
        #expect(receivedHarness == "claude")
    }

    @Test func finiteChoiceCollectionAdvancesInDeclarationOrder() throws {
        let arguments = [
            CmuxActionArgumentDefinition(
                name: "harness",
                title: "Harness",
                choices: [
                    .init(value: "current", title: "Current Harness"),
                    .init(value: "claude", title: "Claude Code"),
                ]
            ),
            CmuxActionArgumentDefinition(
                name: "destination",
                title: "Destination",
                choices: [
                    .init(value: "right", title: "Right Split"),
                    .init(value: "newTab", title: "New Tab"),
                ]
            ),
        ]
        var collection = try #require(CommandPaletteArgumentCollection(
            commandID: "palette.forkAgentConversation",
            arguments: arguments
        ))

        #expect(collection.currentArgument.name == "harness")
        #expect(collection.currentStep == 1)
        #expect(collection.stepCount == 2)
        #expect(collection.selectCurrentChoice(value: "invalid") == .invalid)
        #expect(collection.values.isEmpty)
        #expect(collection.selectCurrentChoice(value: "claude") == .advanced)
        #expect(collection.currentArgument.name == "destination")
        #expect(collection.currentStep == 2)
        #expect(collection.selectCurrentChoice(value: "right") == .completed)
        #expect(collection.values == ["harness": "claude", "destination": "right"])
    }

    @Test func registryUsesStableStringIDsAndRejectsDuplicates() {
        let first = makeCommand(id: "custom.deploy") { _ in .completed }
        let duplicate = makeCommand(id: "custom.deploy") { _ in .presented }
        var registry = CmuxActionRegistry()

        let registeredFirst = registry.register(first)
        let registeredDuplicate = registry.register(duplicate)
        #expect(registeredFirst)
        #expect(!registeredDuplicate)
        #expect(registry.actions.map(\.id) == ["custom.deploy"])
        #expect(registry.run(
            id: "custom.deploy",
            invocation: CmuxActionInvocation(source: .automation)
        ) == .completed)
    }

    @Test func handlerRegistryAlsoKeepsTheFirstOwnerOfAStringID() {
        var registry = CommandPaletteHandlerRegistry()
        registry.register(commandId: "palette.test") { _ in .completed }
        registry.register(commandId: "palette.test") { _ in .presented }

        let result = registry.handler(for: "palette.test")?(
            CmuxActionInvocation(source: .automation)
        )
        #expect(result == .completed)
    }

    private func makeCommand(
        id: String = "palette.test",
        arguments: [CmuxActionArgumentDefinition] = [],
        handler: @escaping CmuxActionHandler
    ) -> CommandPaletteCommand {
        CommandPaletteCommand(
            id: id,
            rank: 0,
            title: "Test",
            subtitle: "Tests",
            shortcutHint: nil,
            kindLabel: nil,
            keywords: [],
            dismissOnRun: true,
            arguments: arguments,
            handler: handler
        )
    }
}
