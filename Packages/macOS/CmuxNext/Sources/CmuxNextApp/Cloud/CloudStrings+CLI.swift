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

    /// `cloud set-idle-pause` with a `minutes` value the server does not take.
    static func idlePauseMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.idlePauseMustBeOneOf", defaultValue: "Minutes must be one of: %@.", table: "Cloud", bundle: .module), list)
    }
}
