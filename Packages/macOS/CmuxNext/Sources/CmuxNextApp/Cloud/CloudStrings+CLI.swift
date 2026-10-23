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

    /// `cloud set-idle-pause` with a `minutes` value the server does not take.
    static func idlePauseMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.cli.idlePauseMustBeOneOf", defaultValue: "Minutes must be one of: %@.", table: "Cloud", bundle: .module), list)
    }
}

/// The cmux Pro offer when a create is refused because the plan has no Cloud
/// machine. Keys live in Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    static var proRequiredTitle: String {
        String(localized: "cloud.pro.required.title", defaultValue: "Cloud machines need cmux Pro", table: "Cloud", bundle: .module)
    }

    static var proRequiredBody: String {
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
