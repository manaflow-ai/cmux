import Foundation

/// Arguments of the room actions (ProfileActions.xcstrings).
nonisolated extension CatalogArgument {
    static var roomRoom: ActionArgument {
        ActionArgument(name: "space", title: ("\u{E000}ProfileActions\u{E001}" + String(describing: "argument.room") + "\u{E002}" + String(localized: "argument.room", defaultValue: "Space", table: "ProfileActions", bundle: .module)),
                       kind: .target(.profile))
    }

    /// Where a deleted room's workspaces go; without it they close.
    static var moveToRoom: ActionArgument {
        ActionArgument(name: "moveTo", title: ("\u{E000}ProfileActions\u{E001}" + String(describing: "argument.moveTo") + "\u{E002}" + String(localized: "argument.moveTo", defaultValue: "Move Workspaces To", table: "ProfileActions", bundle: .module)),
                       kind: .target(.profile))
    }

    /// An SF Symbol name or one emoji.
    static var iconString: ActionArgument {
        ActionArgument(name: "icon", title: ("\u{E000}ProfileActions\u{E001}" + String(describing: "argument.icon") + "\u{E002}" + String(localized: "argument.icon", defaultValue: "Icon", table: "ProfileActions", bundle: .module)),
                       kind: .string)
    }

    static var positionNumber: ActionArgument {
        ActionArgument(name: "index", title: ("\u{E000}ProfileActions\u{E001}" + String(describing: "argument.position") + "\u{E002}" + String(localized: "argument.position", defaultValue: "Position", table: "ProfileActions", bundle: .module)),
                       kind: .int(1...99))
    }
}

/// Arguments of the SSH machine actions (RemoteActions.xcstrings).
nonisolated extension CatalogArgument {
    /// `user@host`, `host` (an alias from `~/.ssh/config`) or `host:port`.
    static var destinationString: ActionArgument {
        ActionArgument(name: "destination", title: ("\u{E000}RemoteActions\u{E001}" + String(describing: "argument.destination") + "\u{E002}" + String(localized: "argument.destination", defaultValue: "SSH Destination", table: "RemoteActions", bundle: .module)),
                       kind: .string)
    }

    /// New Remote Group's host: typed, or picked from the hosts the App lists
    /// (``ActionSuggestions/remoteHosts``).
    static var remoteHostDestination: ActionArgument {
        ActionArgument(name: "destination", title: ("\u{E000}RemoteActions\u{E001}" + String(describing: "argument.destination") + "\u{E002}" + String(localized: "argument.destination", defaultValue: "SSH Destination", table: "RemoteActions", bundle: .module)),
                       kind: .string, suggestions: ActionSuggestions(
                           source: ActionSuggestions.remoteHosts, pinned: [],
                           otherTitle: ("\u{E000}RemoteActions\u{E001}" + String(describing: "argument.remoteGroup.host.other") + "\u{E002}" + String(localized: "argument.remoteGroup.host.other", defaultValue: "Enter Host…", table: "RemoteActions", bundle: .module))))
    }

    /// Where cmux-tui lives on the machine; `~/.local/bin/cmux-tui` when omitted.
    static var binaryString: ActionArgument {
        ActionArgument(name: "binary", title: ("\u{E000}RemoteActions\u{E001}" + String(describing: "argument.binary") + "\u{E002}" + String(localized: "argument.binary", defaultValue: "cmux-tui Path", table: "RemoteActions", bundle: .module)),
                       kind: .string, isRequired: false)
    }

    /// A non-default cmux-tui state directory on the machine.
    static var stateDirString: ActionArgument {
        ActionArgument(name: "stateDir", title: ("\u{E000}RemoteActions\u{E001}" + String(describing: "argument.stateDir") + "\u{E002}" + String(localized: "argument.stateDir", defaultValue: "State Directory", table: "RemoteActions", bundle: .module)),
                       kind: .string, isRequired: false)
    }

    /// The cmux-tui session on the machine; `main` when omitted.
    static var sessionString: ActionArgument {
        ActionArgument(name: "session", title: ("\u{E000}RemoteActions\u{E001}" + String(describing: "argument.session") + "\u{E002}" + String(localized: "argument.session", defaultValue: "Session", table: "RemoteActions", bundle: .module)),
                       kind: .string, isRequired: false)
    }
}
