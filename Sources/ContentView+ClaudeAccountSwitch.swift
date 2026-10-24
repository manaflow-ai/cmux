import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    /// Prefix of the per-account palette command ids. Account names are limited to
    /// `[A-Za-z0-9._-]`, so the id needs no escaping.
    static let claudeAccountSwitchCommandIdPrefix = "palette.switchClaudeAccount."

    /// The palette command id that switches the focused pane to `accountName`.
    static func claudeAccountSwitchCommandId(accountName: String) -> String {
        claudeAccountSwitchCommandIdPrefix + accountName
    }

    /// One "Switch Claude Account: <name>" command per account the focused pane can switch to.
    func claudeAccountSwitchCommandContributions(
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        Self.claudeAccountSwitchCommandContributions(
            targetNames: focusedPaneClaudeAccountSwitchTargetNames(),
            subtitle: subtitle
        )
    }

    /// The switch commands for `targetNames`, shown only on a terminal that hosts Claude.
    static func claudeAccountSwitchCommandContributions(
        targetNames: [String],
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        targetNames.map { accountName in
            CommandPaletteCommandContribution(
                commandId: claudeAccountSwitchCommandId(accountName: accountName),
                title: { _ in
                    String(
                        format: String(
                            localized: "command.switchClaudeAccount.title",
                            defaultValue: "Switch Claude Account: %@"
                        ),
                        accountName
                    )
                },
                subtitle: subtitle,
                keywords: ["claude", "account", "switch", "agent", "config", accountName],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                        $0.bool(CommandPaletteContextKeys.panelHasClaudeAgent)
                }
            )
        }
    }

    /// Registers a handler for each command ``claudeAccountSwitchCommandContributions(subtitle:)``
    /// contributes. Each runs the same ``ClaudeAccountSwitchUserFlow`` as the terminal menu.
    func registerClaudeAccountSwitchHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for accountName in focusedPaneClaudeAccountSwitchTargetNames() {
            registry.register(commandId: Self.claudeAccountSwitchCommandId(accountName: accountName)) {
                guard let context = focusedPanelContext,
                      context.panel.panelType == .terminal else {
                    NSSound.beep()
                    return
                }
                Task { @MainActor in
                    await ClaudeAccountSwitchUserFlow().run(
                        workspace: context.workspace,
                        panelId: context.panelId,
                        accountName: accountName
                    )
                }
            }
        }
    }

    /// The accounts the focused terminal can switch to, from the model the terminal menu uses.
    private func focusedPaneClaudeAccountSwitchTargetNames() -> [String] {
        guard let context = focusedPanelContext,
              context.panel.panelType == .terminal else {
            return []
        }
        return context.workspace.claudeAccountSwitchMenuModel(panelId: context.panelId)?.switchTargetNames ?? []
    }
}
