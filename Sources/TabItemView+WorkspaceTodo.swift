import AppKit
import CmuxCommandPalette
import CmuxWorkspaces
import SwiftUI

// MARK: - Context menu section

/// The workspace-todo entries of the sidebar row's context menu. Lives in
/// its own file because `Sources/ContentView.swift` sits at its file-length
/// budget; the menu builder runs on demand (outside the row's render hot
/// path), so reading `tab`/`tabManager` here is allowed.
extension TabItemView {
    @ViewBuilder
    var workspaceTodoContextMenuSection: some View {
        let inferred = tab.inferredTaskStatus
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: tab.todoState.statusOverride,
            inferred: inferred
        )
        let activeOverride: WorkspaceTaskStatus? = {
            guard let override = tab.todoState.statusOverride,
                  !resolution.shouldClearOverride else { return nil }
            return override.status
        }()
        let isMulti = contextMenuWorkspaceIds.count > 1
        let markDoneLabel = isMulti
            ? String(localized: "contextMenu.markWorkspacesDone", defaultValue: "Mark Workspaces as Done")
            : String(localized: "contextMenu.markWorkspaceDone", defaultValue: "Mark Workspace as Done")
        let markWorkspaceDoneShortcut = KeyboardShortcutSettings.shortcut(for: .markWorkspaceDone)

        // The lane list is shared with the glyph's status popover (one model,
        // one apply path) so both surfaces stay in lockstep.
        let statusLanes = WorkspaceTodoStatusLane.lanes(
            inferred: inferred,
            activeOverride: activeOverride
        )
        Menu(String(localized: "contextMenu.workspaceStatus", defaultValue: "Status")) {
            ForEach(statusLanes) { lane in
                workspaceTodoStatusMenuButton(
                    title: lane.title,
                    isSelected: lane.isSelected
                ) {
                    WorkspaceTodoActions.applyStatusOverride(lane.status, to: workspaceTodoTargetWorkspaces())
                }
                if lane.status == nil {
                    Divider()
                }
            }
        }

        if let key = markWorkspaceDoneShortcut.keyEquivalent {
            Button(markDoneLabel) {
                WorkspaceTodoActions.applyStatusOverride(.done, to: workspaceTodoTargetWorkspaces())
            }
            .keyboardShortcut(key, modifiers: markWorkspaceDoneShortcut.eventModifiers)
        } else {
            Button(markDoneLabel) {
                WorkspaceTodoActions.applyStatusOverride(.done, to: workspaceTodoTargetWorkspaces())
            }
        }

        Button(String(localized: "contextMenu.addChecklistItem", defaultValue: "Add Checklist Item…")) {
            WorkspaceTodoActions.requestChecklistAddField(workspaceId: tab.id)
        }
    }

    /// Mirrors pin's multi-selection behavior: acts on every workspace in the
    /// row's context-menu target set (the sidebar selection when this row is
    /// part of it, otherwise just this row).
    private func workspaceTodoTargetWorkspaces() -> [Workspace] {
        contextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    private func workspaceTodoStatusMenuButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// The closure bundle the checklist subviews receive (value snapshots +
    /// closures only below the snapshot boundary).
    var workspaceTodoChecklistActions: SidebarWorkspaceChecklistActions {
        SidebarWorkspaceChecklistActions(
            setItemState: { [tab] itemId, state in
                WorkspaceTodoActions.setChecklistItemState(id: itemId, state: state, in: tab)
            },
            removeItem: { [tab] itemId in
                WorkspaceTodoActions.removeChecklistItem(id: itemId, from: tab)
            },
            addItem: { [tab] text in
                WorkspaceTodoActions.addChecklistItem(text: text, to: tab)
            },
            openPane: { [tab] in
                WorkspaceTodoActions.openTodoPane(for: tab)
            }
        )
    }
}

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
