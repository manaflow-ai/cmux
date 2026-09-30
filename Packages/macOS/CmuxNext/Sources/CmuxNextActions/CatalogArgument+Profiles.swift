import Foundation

/// Arguments of the room actions (ProfileActions.xcstrings).
nonisolated extension CatalogArgument {
    static var roomRoom: ActionArgument {
        ActionArgument(name: "room", title: String(localized: "argument.room", defaultValue: "Room", table: "ProfileActions", bundle: .module),
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
