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

    /// `cloud enroll-machine` with a name ssh can't use as a host alias.
    static var enrollNameInvalid: String {
        String(localized: "cloud.cli.enrollNameInvalid",
               defaultValue: "The machine's ssh name must be letters, digits, dots, dashes or underscores: pass --name lane-vm-N.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud enroll-machine` on a machine the server gave no private address yet.
    static var enrollNoAddress: String {
        String(localized: "cloud.cli.enrollNoAddress",
               defaultValue: "This Cloud machine has no private address yet, so ssh can't reach it. Try again once it is running.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud enroll-machine --ssh-key FILE` that is not one readable ssh-ed25519 public key.
    static func enrollKeyUnreadable(_ path: String) -> String {
        String(format: String(localized: "cloud.cli.enrollKeyUnreadable",
                              defaultValue: "Can't use the ssh key %@: it must be one ssh-ed25519 public key. Pass --ssh-key with an absolute path.",
                              table: "Cloud", bundle: .module), path)
    }

    /// `cloud enroll-machine`: the machine's side failed; `output` is its own error text.
    static func enrollAuthorizeFailed(_ output: String) -> String {
        String(format: String(localized: "cloud.cli.enrollAuthorizeFailed", defaultValue: "Couldn't set up ssh on the machine: %@",
                              table: "Cloud", bundle: .module), output)
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

    /// `cloud deliver-secrets`: the Keychain would not give this secret's value (locked, or the item is gone).
    static func secretUnreadable(_ name: String) -> String {
        String(format: String(localized: "cloud.cli.secretUnreadable",
                              defaultValue: "Can't read the secret %@ from this Mac's Keychain. Unlock it, or store it again with cmux cloud secret set.",
                              table: "Cloud", bundle: .module), name)
    }

    /// `cloud deliver-secrets` while another delivery to the same machine runs.
    static var secretsDeliveryRunning: String {
        String(localized: "cloud.cli.secretsDeliveryRunning",
               defaultValue: "Secrets are already being delivered to this machine. Try again when that delivery finishes.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud deliver-secrets` before any machine-config apply finished on the machine.
    static var machineConfigNotApplied: String {
        String(localized: "cloud.cli.machineConfigNotApplied",
               defaultValue: "This machine has no finished machine config yet. Run cmux cloud apply-machine-config first, then deliver the secrets.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud deliver-secrets` without `--repo` on a machine set up from a repo that has its own values here.
    static func secretRepoNeeded(_ repo: String) -> String {
        String(format: String(localized: "cloud.cli.secretRepoNeeded",
                              defaultValue: "This machine was set up from %1$@, which has its own secret values on this Mac. Pass --repo %2$@ to deliver them.",
                              table: "Cloud", bundle: .module), repo, repo)
    }

    /// `cloud deliver-secrets` with a secrets index that is there but cannot be read.
    static func secretIndexUnreadable(_ path: String) -> String {
        String(format: String(localized: "cloud.cli.secretIndexUnreadable",
                              defaultValue: "Can't read %@, so nothing was delivered. Fix or remove it, then store the secrets again with cmux cloud secret set.",
                              table: "Cloud", bundle: .module), path)
    }

    /// `cloud deliver-secrets --repo` that is not `OWNER/NAME`.
    static func secretRepoInvalid(_ text: String) -> String {
        String(format: String(localized: "cloud.cli.secretRepoInvalid", defaultValue: "--repo %@ is not OWNER/NAME.",
                              table: "Cloud", bundle: .module), text)
    }

    /// `cloud deliver-secrets`: the machine's receiver did not take the values; `reason` is its answer.
    static func secretsNotDelivered(_ reason: String) -> String {
        String(format: String(localized: "cloud.cli.secretsNotDelivered", defaultValue: "The secrets were not delivered: %@",
                              table: "Cloud", bundle: .module), reason)
    }

    /// `cloud deliver-secrets` to an own machine (SSH or an acpmux peer) without `--names`.
    static var secretNamesRequired: String {
        String(localized: "cloud.cli.secretNamesRequired",
               defaultValue: "Name the secrets this machine gets with --names NAME[,NAME…]. Its secrets file then holds exactly those.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud deliver-secrets --names` that is bare, empty or holds something that is not a secret name.
    static func secretNamesInvalid(_ text: String) -> String {
        String(format: String(localized: "cloud.cli.secretNamesInvalid",
                              defaultValue: "--names %@ is not a comma-separated list of secret names (letters, digits and _).",
                              table: "Cloud", bundle: .module), text)
    }

    /// `cloud deliver-secrets --names` on a Cloud machine, whose machine config declares its names.
    static var secretNamesOnCloudMachine: String {
        String(localized: "cloud.cli.secretNamesOnCloudMachine",
               defaultValue: "A Cloud machine gets the secret names its .cmux/machine.toml declares. Leave out --names.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud deliver-secrets` to an acpmux peer this Mac reaches without ssh (a tailnet link).
    static func secretsNoSSHRoute(_ machine: String) -> String {
        String(format: String(localized: "cloud.cli.secretsNoSSHRoute",
                              defaultValue: "This Mac reaches %@ without ssh, so its secrets can't be delivered. Add it with Add Machine, then try again.",
                              table: "Cloud", bundle: .module), machine)
    }

    /// `cloud deliver-secrets --names` where none of the names has a value on this Mac.
    static func secretsNoneStored(_ names: String) -> String {
        String(format: String(localized: "cloud.cli.secretsNoneStored",
                              defaultValue: "None of %@ has a value on this Mac, so nothing was delivered. Store each with cmux cloud secret set NAME.",
                              table: "Cloud", bundle: .module), names)
    }

    /// `--machine-config FILE` that cannot be read, is empty or is over 64 KB.
    static func machineConfigUnreadable(_ path: String) -> String {
        String(format: String(localized: "cloud.cli.machineConfigUnreadable",
                              defaultValue: "Can't use the machine config %@: it must be a readable file of at most 64 KB.",
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

    /// `cloud new-machine --repo` that is not a GitHub repository in an accepted form.
    static var repoUnrecognized: String {
        String(localized: "cloud.cli.repoUnrecognized",
               defaultValue: "--repo takes a GitHub repository: OWNER/NAME, https://github.com/OWNER/NAME or git@github.com:OWNER/NAME.git, with an optional @REF.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --repo` with a token or password in the URL.
    static var repoCredentialsInURL: String {
        String(localized: "cloud.cli.repoCredentialsInURL",
               defaultValue: "--repo carries credentials. Remove them: the machine uses the GitHub access it already has, and no token is written to it.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --repo OWNER/NAME@REF` whose REF is not a plain branch, tag or commit.
    static var repoInvalidRef: String {
        String(localized: "cloud.cli.repoInvalidRef",
               defaultValue: "The @REF of --repo must be a branch, tag or commit of letters, digits, dots, dashes, underscores and slashes.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud set-idle-pause` with a `minutes` value the server does not take.
    static func idlePauseMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.idlePauseMustBeOneOf", defaultValue: "Minutes must be one of: %@.", table: "Cloud", bundle: .module), list)
    }

    /// `cloud set-network-access` with an `access` value that is not a level.
    static func networkAccessMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.networkAccessMustBeOneOf", defaultValue: "Access must be one of: %@.", table: "Cloud", bundle: .module), list)
    }

    /// An agent's `cloud set-network-access` that would let the machine reach more than it can now.
    static var networkAccessAgentWidens: String {
        String(localized: "cloud.cli.networkAccessAgentWidens",
               defaultValue: "An agent can only turn a machine's internet access off. To choose another level, use Internet Access… in the machine's menu.",
               table: "Cloud", bundle: .module)
    }
}

/// The cmux Pro offer when a create is refused because the plan has no Cloud
/// machine. Keys live in Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    static var proRequiredTitle: String {
        String(localized: "cloud.pro.required.title", defaultValue: "Cloud machines need cmux Pro", table: "Cloud", bundle: .module)
    }

    nonisolated static var proRequiredBody: String {
        String(localized: "cloud.pro.required.body",
               defaultValue: "Your plan doesn't include Cloud machines. Upgrade to cmux Pro to create them, for you and for Chief.",
               table: "Cloud", bundle: .module)
    }

    static var proRequiredUpgrade: String {
        String(localized: "cloud.pro.required.upgrade", defaultValue: "Upgrade to cmux Pro", table: "Cloud", bundle: .module)
    }
}

/// Open Desktop (``CloudDesktop``). Keys live in Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    /// The desktop workspace's name: the machine's title, then "Desktop".
    static func desktopWorkspaceName(_ machine: String) -> String {
        String(format: String(localized: "cloud.desktop.workspaceName", defaultValue: "%@ Desktop", table: "Cloud", bundle: .module), machine)
    }

    /// A machine made shell-only, or one with no address on its Cloud network yet.
    static func desktopUnavailable(_ machine: String) -> String {
        String(format: String(localized: "cloud.desktop.unavailable", defaultValue: "%@ has no desktop to open.", table: "Cloud", bundle: .module), machine)
    }
}
