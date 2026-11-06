import Foundation

/// Arguments of `cmux open-remote` (manaflow-ai/cmux#25092). Titles reuse the shared
/// `argument.*` keys; `attach` and `ratio` are new (Localizable.xcstrings).
nonisolated extension CatalogArgument {
    /// The machine by id, name or ssh destination (matched by ``OpenRemoteMachine/match(_:in:)``).
    static var openRemoteHost: ActionArgument {
        ActionArgument(name: "host", title: ("\u{E000}WorkspaceActions\u{E001}" + String(describing: "argument.machine") + "\u{E002}" + String(localized: "argument.machine", defaultValue: "Machine", table: "WorkspaceActions", bundle: .module)), kind: .string)
    }

    /// `tab`, `right`, `down` (aliases `below`, `bottom`).
    static var openRemoteSplit: ActionArgument {
        ActionArgument(name: "split", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.direction") + "\u{E002}" + String(localized: "argument.direction", defaultValue: "Direction", bundle: .module)), kind: .string, isRequired: false)
    }

    static var openRemoteCmd: ActionArgument {
        ActionArgument(name: "cmd", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.command") + "\u{E002}" + String(localized: "argument.command", defaultValue: "Command", bundle: .module)), kind: .string, isRequired: false)
    }

    /// Rex's `--label`: the same as `name`.
    static var openRemoteLabel: ActionArgument {
        ActionArgument(name: "label", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.name") + "\u{E002}" + String(localized: "argument.name", defaultValue: "Name", bundle: .module)), kind: .string, isRequired: false)
    }

    /// The name of a terminal already running on the machine.
    static var openRemoteAttach: ActionArgument {
        ActionArgument(name: "attach", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.attach") + "\u{E002}" + String(localized: "argument.attach", defaultValue: "Attach To", bundle: .module)), kind: .string, isRequired: false)
    }

    /// The new pane's share, between 0 and 1.
    static var openRemoteRatio: ActionArgument {
        ActionArgument(name: "ratio", title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.ratio") + "\u{E002}" + String(localized: "argument.ratio", defaultValue: "Size Ratio", bundle: .module)), kind: .string, isRequired: false)
    }
}
