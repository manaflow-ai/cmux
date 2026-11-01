import Foundation

/// Arguments of `cmux open-remote` (manaflow-ai/cmux#25092). Titles reuse the shared
/// `argument.*` keys; `attach` and `ratio` are new (Localizable.xcstrings).
nonisolated extension CatalogArgument {
    /// The machine by id, name or ssh destination (matched by ``OpenRemoteMachine/match(_:in:)``).
    static var openRemoteHost: ActionArgument {
        ActionArgument(name: "host", title: String(localized: "argument.machine", defaultValue: "Machine", table: "WorkspaceActions", bundle: .module), kind: .string)
    }

    /// `tab`, `right`, `down` (aliases `below`, `bottom`).
    static var openRemoteSplit: ActionArgument {
        ActionArgument(name: "split", title: String(localized: "argument.direction", defaultValue: "Direction", bundle: .module), kind: .string, isRequired: false)
    }

    static var openRemoteCmd: ActionArgument {
        ActionArgument(name: "cmd", title: String(localized: "argument.command", defaultValue: "Command", bundle: .module), kind: .string, isRequired: false)
    }

    /// Rex's `--label`: the same as `name`.
    static var openRemoteLabel: ActionArgument {
        ActionArgument(name: "label", title: String(localized: "argument.name", defaultValue: "Name", bundle: .module), kind: .string, isRequired: false)
    }

    /// The name of a terminal already running on the machine.
    static var openRemoteAttach: ActionArgument {
        ActionArgument(name: "attach", title: String(localized: "argument.attach", defaultValue: "Attach To", bundle: .module), kind: .string, isRequired: false)
    }

    /// The new pane's share, between 0 and 1.
    static var openRemoteRatio: ActionArgument {
        ActionArgument(name: "ratio", title: String(localized: "argument.ratio", defaultValue: "Size Ratio", bundle: .module), kind: .string, isRequired: false)
    }
}
