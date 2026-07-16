import AppKit
import CmuxCommandPalette
import CmuxWorkspaces

// MARK: - Command palette entries

/// Palette contributions and handlers for the workspace-todo actions. Split
/// out of `commandPaletteCommandContributions()` so the ContentView delta
/// stays a two-line append/register.
@MainActor
enum WorkspaceTodoPaletteCommands {
    static let markWorkspaceDoneCommandId = "palette.markWorkspaceDone"
    private static let statusAutoCommandId = "palette.workspaceStatusAuto"
    private static let addChecklistItemCommandId = "palette.addWorkspaceChecklistItem"
    private static let openTodoPaneCommandId = "palette.openWorkspaceTodoPane"

    private static func statusCommandId(_ status: WorkspaceTaskStatus) -> String {
        "palette.workspaceStatus.\(status.rawValue)"
    }

    private static func statusTitle(_ status: WorkspaceTaskStatus) -> String {
        String(
            format: String(
                localized: "command.workspaceStatus.title",
                defaultValue: "Workspace Status: %@"
            ),
            locale: .current,
            status.displayName
        )
    }

    static func contributions(
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        let hasWorkspace: (CommandPaletteContextSnapshot) -> Bool = {
            $0.bool(CommandPaletteContextKeys.hasWorkspace)
        }
        var contributions: [CommandPaletteCommandContribution] = []
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: statusAutoCommandId,
                title: { _ in
                    String(
                        localized: "command.workspaceStatusAuto.title",
                        defaultValue: "Workspace Status: Auto"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "status", "todo", "auto", "inferred", "clear"],
                when: hasWorkspace
            )
        )
        for status in WorkspaceTaskStatus.allCases {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: statusCommandId(status),
                    title: { _ in statusTitle(status) },
                    subtitle: workspaceSubtitle,
                    keywords: ["workspace", "status", "todo", "lane", status.rawValue],
                    when: hasWorkspace
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: markWorkspaceDoneCommandId,
                title: { _ in
                    String(
                        localized: "command.markWorkspaceDone.title",
                        defaultValue: "Mark Workspace as Done"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "done", "complete", "finish", "todo", "status"],
                when: hasWorkspace
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: addChecklistItemCommandId,
                title: { _ in
                    String(
                        localized: "command.addWorkspaceChecklistItem.title",
                        defaultValue: "Add Checklist Item…"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "checklist", "todo", "task", "add", "item"],
                when: hasWorkspace
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: openTodoPaneCommandId,
                title: { _ in
                    String(
                        localized: "command.openWorkspaceTodoPane.title",
                        defaultValue: "Open Todo Pane"
                    )
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "todo", "todos", "checklist", "pane", "open"],
                when: hasWorkspace
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
                guard let workspace = tabManager.selectedWorkspace else {
                    NSSound.beep()
                    return
                }
                body(workspace)
            }
        }
        registry.register(
            commandId: statusAutoCommandId,
            handler: withSelectedWorkspace { workspace in
                WorkspaceTodoActions.applyStatusOverride(nil, to: [workspace])
            }
        )
        for status in WorkspaceTaskStatus.allCases {
            registry.register(
                commandId: statusCommandId(status),
                handler: withSelectedWorkspace { workspace in
                    WorkspaceTodoActions.applyStatusOverride(status, to: [workspace])
                }
            )
        }
        registry.register(
            commandId: markWorkspaceDoneCommandId,
            handler: withSelectedWorkspace { workspace in
                WorkspaceTodoActions.applyStatusOverride(.done, to: [workspace])
            }
        )
        registry.register(
            commandId: addChecklistItemCommandId,
            handler: withSelectedWorkspace { workspace in
                WorkspaceTodoActions.requestChecklistAddField(workspaceId: workspace.id)
            }
        )
        registry.register(
            commandId: openTodoPaneCommandId,
            handler: withSelectedWorkspace { workspace in
                if WorkspaceTodoActions.openTodoPane(for: workspace) == nil {
                    NSSound.beep()
                }
            }
        )
    }
}
