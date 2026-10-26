import Foundation

/// What a CLI or agent run of a Cloud action hears back. Keys live in
/// Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    /// `cloud new-machine` from a CLI or agent: the person said no in the confirmation, or
    /// dismissed the creation, so no machine was made.
    static var createDeclined: String {
        String(localized: "cloud.cli.createDeclined", defaultValue: "No Cloud machine was created: the person declined or dismissed it in cmux.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud exec` from a CLI or agent on a machine whose provider runs no commands through the
    /// API: typing it into a tab would give the caller nothing to read.
    static func execUnavailable(_ machineID: String) -> String {
        String(format: String(localized: "cloud.cli.execUnavailable",
                              defaultValue: "This Cloud machine can't run a command for the CLI and return its output. Open a terminal on it with `cmux cloud new-terminal-on-machine --target machine:%1$@`, or connect with `cmux cloud ssh --target machine:%1$@`.",
                              table: "Cloud", bundle: .module), machineID)
    }

    /// A run whose `--target machine:<id>` names no machine this app knows.
    static func unknownMachine(_ machineID: String) -> String {
        String(format: String(localized: "cloud.cli.unknownMachine",
                              defaultValue: "No Cloud machine has the id %@. `cmux cloud list-machines` lists ids.",
                              table: "Cloud", bundle: .module), machineID)
    }

    /// `cloud new-terminal-on-machine --workspace <id>` naming no workspace of that machine.
    static func noSuchMachineWorkspace(_ machine: String, _ workspace: String) -> String {
        String(format: String(localized: "cloud.cli.noSuchMachineWorkspace",
                              defaultValue: "Machine `%1$@` has no workspace `%2$@`. `cmux cloud new-terminal-on-machine --target machine:%1$@` makes one.",
                              table: "Cloud", bundle: .module), machine, workspace)
    }

    /// `cloud new-terminal-on-machine --workspace` with no id after it.
    static func machineWorkspaceRequired(_ machine: String) -> String {
        String(format: String(localized: "cloud.cli.machineWorkspaceRequired",
                              defaultValue: "Pass the workspace id after --workspace: the workspace_id `cmux cloud new-terminal-on-machine --target machine:%1$@` answered. Leave --workspace out to make a new workspace.",
                              table: "Cloud", bundle: .module), machine)
    }

    /// `cloud new-terminal-on-machine --workspace <id>` on a workspace the app has no pane of yet.
    static func machineWorkspaceHasNoPane(_ machine: String, _ workspace: String) -> String {
        String(format: String(localized: "cloud.cli.machineWorkspaceHasNoPane",
                              defaultValue: "Workspace `%2$@` on machine `%1$@` has no pane to open a terminal in yet. Run the command again, or `cmux cloud new-terminal-on-machine --target machine:%1$@` makes a new workspace.",
                              table: "Cloud", bundle: .module), machine, workspace)
    }

    /// `cloud new-terminal-on-machine --workspace <id>` when the machine's daemon did not catch the
    /// app's copy of its workspaces up, so the id can't be checked yet.
    static func machineWorkspacesNotLoaded(_ machine: String, _ workspace: String) -> String {
        String(format: String(localized: "cloud.cli.machineWorkspacesNotLoaded",
                              defaultValue: "Machine `%1$@` did not report its workspaces in time, so workspace `%2$@` can't be found yet. Run the command again, or `cmux cloud new-terminal-on-machine --target machine:%1$@` makes a new workspace.",
                              table: "Cloud", bundle: .module), machine, workspace)
    }

    /// `cloud new-machine --bootstrap lane` (or a bootstrap kind it does not know) with no script.
    static var bootstrapScriptRequired: String {
        String(localized: "cloud.cli.bootstrapScriptRequired",
               defaultValue: "A bootstrap needs its script: pass --bootstrap-script FILE with --bootstrap lane or none.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --name` that is not a plain name (or has no value).
    static var machineNameInvalid: String {
        String(localized: "cloud.cli.machineNameInvalid",
               defaultValue: "The machine's name must be 1 to 64 letters, digits, dots, dashes or underscores, such as lane-vm-1.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --bootstrap-script FILE` that cannot be read, is empty or is over 1 MB.
    static func bootstrapScriptUnreadable(_ path: String) -> String {
        String(format: String(localized: "cloud.cli.bootstrapScriptUnreadable",
                              defaultValue: "Can't use the bootstrap script %@: it must be a readable file of at most 1 MB.",
                              table: "Cloud", bundle: .module), path)
    }

    /// `cloud new-machine --bootstrap lane` with no `--name`: the lane bootstrap names the host after it.
    static var laneNeedsName: String {
        String(localized: "cloud.cli.laneNeedsName", defaultValue: "The lane bootstrap needs the machine's name: pass --name lane-vm-N.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine` with any option on a Cloud backend whose create takes none yet.
    static var machineOptionsUnavailable: String {
        String(localized: "cloud.cli.machineOptionsUnavailable",
               defaultValue: "This Cloud backend can't create a machine with a size, idle pause, name or bootstrap yet. Create it without them, then use cloud resize-machine, cloud set-idle-pause and cloud rename-machine.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud set-idle-pause` with a `minutes` value the server does not take.
    static func idlePauseMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.idlePauseMustBeOneOf", defaultValue: "Minutes must be one of: %@.", table: "Cloud", bundle: .module), list)
    }
}
