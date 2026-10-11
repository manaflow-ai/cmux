import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    static let agentMessagesToggleCommandId = "palette.toggleAgentMessages"
    /// True when the focused terminal turned agent messages off.
    static let agentMessagesDisabledContextKey = CommandPaletteContextKeys(rawValue: "panel.agentMessagesDisabled")

    /// Turns agent messages off or on for the focused terminal, through the
    /// same ``AgentMessageCenter/setReceivingEnabled(_:scope:id:)`` path as
    /// `cmux agent messages off|on`.
    static func commandPaletteAgentMessagesContributions(
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: agentMessagesToggleCommandId,
                title: { context in
                    context.bool(agentMessagesDisabledContextKey)
                        ? String(localized: "command.agentMessagesOn.title", defaultValue: "Turn On Agent Messages for This Tab")
                        : String(localized: "command.agentMessagesOff.title", defaultValue: "Turn Off Agent Messages for This Tab")
                },
                subtitle: subtitle,
                keywords: ["agent", "message", "messages", "inbox", "mute", "disable", "enable", "off", "on", "communication"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            ),
        ]
    }

    static func setCommandPaletteAgentMessagesContext(panelId: UUID, in snapshot: inout CommandPaletteContextSnapshot) {
        snapshot.setBool(agentMessagesDisabledContextKey, AgentMessageCenter.isReceivingDisabled(scope: .surface, id: panelId))
    }

    func registerAgentMessagesCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.agentMessagesToggleCommandId) {
            guard let panelContext = focusedPanelContext,
                  panelContext.panel.panelType == .terminal else {
                NSSound.beep()
                return
            }
            let disabled = AgentMessageCenter.isReceivingDisabled(scope: .surface, id: panelContext.panelId)
            do {
                try AgentMessageCenter.setReceivingEnabled(
                    disabled,
                    scope: .surface,
                    id: panelContext.panelId,
                    openRecipients: disabled ? nil : AgentMessageCenter.openRecipientsIfAtCapacity()
                )
            } catch {
                NSSound.beep()
            }
        }
    }
}
