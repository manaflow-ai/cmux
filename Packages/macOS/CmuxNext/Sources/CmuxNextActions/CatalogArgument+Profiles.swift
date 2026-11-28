import Foundation

/// Arguments of the room actions (ProfileActions.xcstrings).
nonisolated extension CatalogArgument {
    static var roomRoom: ActionArgument {
        ActionArgument(name: "space", title: String(localized: "argument.room", defaultValue: "Space", table: "ProfileActions", bundle: .module),
                       kind: .target(.profile))
    }

    /// Where a deleted room's workspaces go; without it they close.
    static var moveToRoom: ActionArgument {
        ActionArgument(name: "moveTo", title: String(localized: "argument.moveTo", defaultValue: "Move Workspaces To", table: "ProfileActions", bundle: .module),
                       kind: .target(.profile))
    }

    /// An SF Symbol name or one emoji.
    static var iconString: ActionArgument {
        ActionArgument(name: "icon", title: String(localized: "argument.icon", defaultValue: "Icon", table: "ProfileActions", bundle: .module),
                       kind: .string)
    }

    static var positionNumber: ActionArgument {
        ActionArgument(name: "index", title: String(localized: "argument.position", defaultValue: "Position", table: "ProfileActions", bundle: .module),
                       kind: .int(1...99))
    }
}

/// Arguments of the SSH machine actions (RemoteActions.xcstrings).
nonisolated extension CatalogArgument {
    /// `user@host`, `host` (an alias from `~/.ssh/config`) or `host:port`.
    static var destinationString: ActionArgument {
        ActionArgument(name: "destination", title: String(localized: "argument.destination", defaultValue: "SSH Destination", table: "RemoteActions", bundle: .module),
                       kind: .string)
    }

    /// Where cmux-tui lives on the machine; `~/.local/bin/cmux-tui` when omitted.
    static var binaryString: ActionArgument {
        ActionArgument(name: "binary", title: String(localized: "argument.binary", defaultValue: "cmux-tui Path", table: "RemoteActions", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// A non-default cmux-tui state directory on the machine.
    static var stateDirString: ActionArgument {
        ActionArgument(name: "stateDir", title: String(localized: "argument.stateDir", defaultValue: "State Directory", table: "RemoteActions", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// The cmux-tui session on the machine; `main` when omitted.
    static var sessionString: ActionArgument {
        ActionArgument(name: "session", title: String(localized: "argument.session", defaultValue: "Session", table: "RemoteActions", bundle: .module),
                       kind: .string, isRequired: false)
    }
}
