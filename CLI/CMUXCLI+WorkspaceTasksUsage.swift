import Foundation

extension CMUXCLI {
    func workspaceTasksUsage() -> String {
        String(localized: "cli.workspaceTasks.usage", defaultValue: """
        Usage: cmux workspace tasks <subcommand> [flags]

        Manage the selected workspace's beta Workspace Tasks list.

        Subcommands:
          list [workspace]                         List open and archived tasks
          add [title] [--title <text>] [--index <n>|--before <task-uuid>|--after <task-uuid>]
                                                  Add an open task
          archive <task-uuid>                      Move a task to Archived
          unarchive <task-uuid>                    Restore a task to Open
          remove <task-uuid>                       Delete a task
          move <task-uuid>|--task <task-uuid>|--task-id <task-uuid>|--id <task-uuid>
               (--index <n>|--before <task-uuid>|--after <task-uuid>)
                                                  Reorder a task within its bucket
          open [workspace] [--focus <true|false>]  Open the native task surface

        Shared flags:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID, then selected)
          --window <id|ref|index>      Window context for workspace refs and indexes

        Examples:
          cmux workspace tasks list
          cmux workspace tasks add "Write PR description"
          cmux workspace tasks add --title "Update docs" --after 3F1D7E18-668E-4A1E-B9E2-83F48139C4E5
          cmux workspace tasks archive 3F1D7E18-668E-4A1E-B9E2-83F48139C4E5
          cmux workspace tasks unarchive 3F1D7E18-668E-4A1E-B9E2-83F48139C4E5
          cmux workspace tasks move 3F1D7E18-668E-4A1E-B9E2-83F48139C4E5 --index 0
          cmux workspace tasks open --focus true
        """)
    }
}
