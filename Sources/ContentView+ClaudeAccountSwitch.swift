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

    /// The accounts the focused terminal can switch to, from the model the terminal menu uses.
    /// Read once per palette build and passed to both the commands and their handlers, so the
    /// two always name the same accounts.
    func focusedPaneClaudeAccountSwitchTargetNames() -> [String] {
        guard let context = focusedPanelContext,
              context.panel.panelType == .terminal else {
            return []
        }
        return context.workspace.claudeAccountSwitchMenuModel(panelId: context.panelId)?.switchTargetNames ?? []
    }

    /// One "Switch Claude Account: <name>" command per name in `targetNames`, shown only on a
    /// terminal that hosts Claude.
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

    /// Registers a handler for each command
    /// ``claudeAccountSwitchCommandContributions(targetNames:subtitle:)`` makes from the same
    /// `targetNames`. Each runs the same ``ClaudeAccountSwitchUserFlow`` as the terminal menu, on
    /// the pane focused now, in the same palette build that read `targetNames` from it.
    func registerClaudeAccountSwitchHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        targetNames: [String]
    ) {
        var pane: (workspace: Workspace, panelId: UUID)?
        if let context = focusedPanelContext, context.panel.panelType == .terminal {
            pane = (context.workspace, context.panelId)
        }
        Self.registerClaudeAccountSwitchHandlers(&registry, targetNames: targetNames, pane: pane) { workspace, panelId, accountName in
            Task { @MainActor in
                await ClaudeAccountSwitchUserFlow().run(
                    workspace: workspace,
                    panelId: panelId,
                    accountName: accountName
                )
            }
        }
    }

    /// Registers, for each name in `targetNames`, a handler under its switch command id that calls
    /// `run` with `pane` and that name. `pane` is the terminal the names were read from: a handler
    /// that runs after focus moved still switches it, and beeps instead once its workspace no
    /// longer has it as a terminal.
    static func registerClaudeAccountSwitchHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        targetNames: [String],
        pane: (workspace: Workspace, panelId: UUID)?,
        run: @escaping (_ workspace: Workspace, _ panelId: UUID, _ accountName: String) -> Void
    ) {
        let workspace = pane?.workspace
        let panelId = pane?.panelId
        for accountName in targetNames {
            registry.register(commandId: claudeAccountSwitchCommandId(accountName: accountName)) { [weak workspace] in
                guard let workspace, let panelId, workspace.terminalPanel(for: panelId) != nil else {
                    NSSound.beep()
                    return
                }
                run(workspace, panelId, accountName)
            }
        }
    }
}
