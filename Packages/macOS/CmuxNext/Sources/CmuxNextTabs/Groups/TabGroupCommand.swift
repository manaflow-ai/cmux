public import CmuxNextDesign

/// Group-level commands. Each maps to one action in the App's registry
/// (`actionID`), so the editor bubble, context menus, palette, shortcuts, and
/// CLI all run the same handler. The strip's editor bubble emits these as
/// `TabStripIntent.group`.
public enum TabGroupCommand: Hashable, Sendable {
    case rename(TabGroupID, name: String)
    case setColor(TabGroupID, GroupColor)
    case newTab(TabGroupID)
    case ungroup(TabGroupID)
    case close(TabGroupID)
    case moveToNewWindow(TabGroupID)
    case save(TabGroupID)
    case unsave(TabGroupID)

    public var groupID: TabGroupID {
        switch self {
        case .rename(let id, _), .setColor(let id, _), .newTab(let id), .ungroup(let id),
             .close(let id), .moveToNewWindow(let id), .save(let id), .unsave(let id):
            id
        }
    }

    /// Registry action id (also the `cmux.json` shortcut key).
    public var actionID: String {
        switch self {
        case .rename: "tabGroup.rename"
        case .setColor: "tabGroup.setColor"
        case .newTab: "tabGroup.newTab"
        case .ungroup: "tabGroup.ungroup"
        case .close: "tabGroup.close"
        case .moveToNewWindow: "tabGroup.moveToNewWindow"
        case .save: "tabGroup.save"
        case .unsave: "tabGroup.unsave"
        }
    }

    /// Action arguments by schema name, for `action.run`.
    public var arguments: [String: String] {
        var args = ["group": groupID.rawValue]
        switch self {
        case .rename(_, let name): args["name"] = name
        case .setColor(_, let color): args["color"] = color.rawValue
        default: break
        }
        return args
    }
}
