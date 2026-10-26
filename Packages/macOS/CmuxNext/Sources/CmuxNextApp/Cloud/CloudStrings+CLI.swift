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
    static var execUnavailable: String {
        String(localized: "cloud.cli.execUnavailable",
               defaultValue: "This Cloud machine can't run a command for the CLI and return its output. Open a terminal on it with cmux cloud open-machine instead.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud new-machine --bootstrap lane` (or a bootstrap kind it does not know) with no script.
    static var bootstrapScriptRequired: String {
        String(localized: "cloud.cli.bootstrapScriptRequired",
               defaultValue: "A bootstrap needs its script: pass --bootstrap-script FILE with --bootstrap lane or none.",
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

    /// `cloud new-machine --size` or `--persistent` on a Cloud backend whose create takes neither yet.
    static var machineOptionsUnavailable: String {
        String(localized: "cloud.cli.machineOptionsUnavailable",
               defaultValue: "This Cloud backend can't set a new machine's size or idle pause yet. Create it without them, then use cloud resize-machine and cloud set-idle-pause.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud set-idle-pause` with a `minutes` value the server does not take.
    static func idlePauseMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.idlePauseMustBeOneOf", defaultValue: "Minutes must be one of: %@.", table: "Cloud", bundle: .module), list)
    }
}
