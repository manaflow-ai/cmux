import AppKit
import CMUXAgentLaunch
import CmuxCommandPalette

/// Palette contributions and handlers for the session-priority controls. Shown
/// only while `automation.sessionPriority.enabled` is on.
@MainActor
enum SessionPriorityPaletteCommands {
    static let manualOnCommandId = "palette.sessionPriorityManual.on"
    static let manualOffCommandId = "palette.sessionPriorityManual.off"

    static func difficultyCommandId(_ difficulty: ClaudeSessionDifficulty?) -> String {
        "palette.claudeDifficulty.\(difficulty?.rawValue ?? "auto")"
    }

    private static func difficultyTitle(_ difficulty: ClaudeSessionDifficulty?) -> String {
        String(
            format: String(
                localized: "command.claudeDifficulty.title",
                defaultValue: "Claude Difficulty: %@"
            ),
            locale: .current,
            SessionPriorityActions.difficultyTitle(difficulty)
        )
    }

    /// Whether the selected workspace is adjustable-manual (flag, or a seen `/effort`).
    private static func selectedWorkspaceIsAdjustableManual() -> Bool {
        guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace else { return false }
        return SessionPriorityMenuState(workspace: workspace).adjustableManual
    }

    static func contributions(
        isEnabled: Bool? = nil,
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        guard isEnabled ?? SessionPriorityCoordinator.shared.isEnabled else { return [] }
        let hasWorkspace: (CommandPaletteContextSnapshot) -> Bool = {
            $0.bool(CommandPaletteContextKeys.hasWorkspace)
        }
        var contributions: [CommandPaletteCommandContribution] = SessionPriorityActions.difficultyChoices.map { difficulty in
            CommandPaletteCommandContribution(
                commandId: difficultyCommandId(difficulty),
                title: { _ in difficultyTitle(difficulty) },
                subtitle: workspaceSubtitle,
                keywords: ["claude", "difficulty", "effort", "session", "priority", difficulty?.rawValue ?? "auto"],
                when: hasWorkspace
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: manualOnCommandId,
                title: { _ in
                    String(
                        localized: "command.sessionPriorityManual.on.title",
                        defaultValue: "Session Priority: Don't Adjust This Workspace"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["claude", "effort", "session", "priority", "manual", "off", "stop", "adjust"],
                when: { hasWorkspace($0) && !selectedWorkspaceIsAdjustableManual() }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: manualOffCommandId,
                title: { _ in
                    String(
                        localized: "command.sessionPriorityManual.off.title",
                        defaultValue: "Session Priority: Adjust Automatically"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["claude", "effort", "session", "priority", "automatic", "auto", "on", "adjust"],
                when: { hasWorkspace($0) && selectedWorkspaceIsAdjustableManual() }
            )
        )
        return contributions
    }

    static func registerHandlers(
        in registry: inout CommandPaletteHandlerRegistry,
        tabManager: TabManager
    ) {
        func withSelectedWorkspace(_ body: @escaping (Workspace) -> Void) -> () -> Void {
            {
                guard SessionPriorityCoordinator.shared.isEnabled,
                      let workspace = tabManager.selectedWorkspace else {
                    NSSound.beep()
                    return
                }
                body(workspace)
            }
        }
        for difficulty in SessionPriorityActions.difficultyChoices {
            registry.register(
                commandId: difficultyCommandId(difficulty),
                handler: withSelectedWorkspace { SessionPriorityActions.applyDifficulty(difficulty, to: [$0]) }
            )
        }
        registry.register(
            commandId: manualOnCommandId,
            handler: withSelectedWorkspace { SessionPriorityActions.setManual(true, for: [$0]) }
        )
        registry.register(
            commandId: manualOffCommandId,
            handler: withSelectedWorkspace { SessionPriorityActions.setManual(false, for: [$0]) }
        )
    }
}
