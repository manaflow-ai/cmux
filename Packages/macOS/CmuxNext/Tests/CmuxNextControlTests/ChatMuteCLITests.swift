import CmuxNextActions
@testable import CmuxNextControl
import Foundation
import Testing

/// Mute or Unmute Chat Notifications worked only from the tab menu: the CLI and MCP left it out as
/// unimplemented, so a script could not mute an agent chat. It is a CLI verb on a tab target, and an
/// MCP tool.
@MainActor @Suite struct ChatMuteCLITests {
    @Test func theCLIVerbNamesTheChatMuteOnATab() throws {
        let catalog = RegistryControlBridge.catalog(from: ActionRegistry.standard())
        let action = try ControlRouter.resolveAction(
            ["action": .string("tab toggle-chat-notifications"), "cli": .bool(true)], in: catalog)
        #expect(action.id == "agentChat.toggleNotificationMute")
        #expect(action.targets == ["tab"])
        #expect(action.surfaces["mcp"] == "offered", "MCP offers it: \(action.surfaces)")
    }
}
