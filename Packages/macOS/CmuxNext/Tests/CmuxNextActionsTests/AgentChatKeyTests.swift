import AppKit
import CmuxNextActions
import Testing

/// The Codex app's chat keys in an agent chat (cx-ncc.72): a key press resolves to the action the
/// key router runs, as it does for a press in the chat's page.
@MainActor @Suite struct AgentChatKeyTests {
    @Test(arguments: [
        ("p", NSEvent.ModifierFlags([.option, .command]), "palette.toggleTabPin"),
        (";", NSEvent.ModifierFlags([.option, .command]), "agentPane.copyLastCodeBlock"),
        ("a", NSEvent.ModifierFlags([.control, .command]), "agentPane.archiveChat"),
    ])
    func keyInAnAgentChatRunsItsAction(key: String, modifiers: NSEvent.ModifierFlags, action: String) throws {
        // The app binds a handler to every catalog action; a key runs only a bound one.
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = [.agentPaneFocused]
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ))
        #expect(registry.resolveShortcut(for: event)?.id.rawValue == action)
    }
}
