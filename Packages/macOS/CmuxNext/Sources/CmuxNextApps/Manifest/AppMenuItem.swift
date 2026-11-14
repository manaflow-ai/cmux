public import Foundation

/// Manifest v2 `contributes.menus`: a row an app adds to one of cmux's own
/// right-click menus. It runs one of the app's own catalog ops (`apps-run`)
/// with the right-clicked object as `args.target` (`{kind, id}`). The Rust
/// validator (`cmux-app-manifest` `menus.rs`) checks the rules; chat-area
/// menus are not offered.
public nonisolated struct AppMenuItem: Sendable, Hashable, Identifiable {
    /// The menu the row is in (`cmux-app-manifest` `MENU_TARGETS`).
    public enum Target: String, Sendable, Hashable, CaseIterable {
        /// A sidebar workspace row's menu.
        case workspace
        /// A tab's menu.
        case tab
        /// A terminal's menu.
        case terminal

        /// The menu of a right-click menu context (`ActionMenuContext` raw value): the workspace
        /// row's, the tab's and the terminal's. Every other menu (chat areas among them) takes no app rows.
        public init?(menuContext: String) {
            switch menuContext {
            case "workspaceRow": self = .workspace
            case "tab": self = .tab
            case "terminalSelection": self = .terminal
            default: return nil
            }
        }
    }

    public var id: String
    public var target: Target
    public var title: AppLocalizedText
    public var symbol: String?
    /// One of the app's own catalog ops.
    public var op: String
    public var args: AppJSON?
    public var order: Int?

    /// The rows under `contributes.menus` of a manifest document; a row for a menu this
    /// version does not know is skipped.
    static func list(_ manifest: AppJSON) -> [AppMenuItem] {
        manifest["contributes"]?["menus"]?.arrayValue?.compactMap(AppMenuItem.init(json:)) ?? []
    }

    init?(json: AppJSON) {
        guard let id = json["id"]?.stringValue, let target = json["target"]?.stringValue.flatMap(Target.init(rawValue:)),
              let title = AppLocalizedText(json: json["title"]), let op = json["op"]?.stringValue else { return nil }
        self.id = id
        self.target = target
        self.title = title
        self.op = op
        symbol = json["icon"]?["symbol"]?.stringValue
        args = json["args"]
        order = json["order"]?.numberValue.map { Int($0) }
    }

    /// The op's arguments for a right-click on `subject` (`kind`, `id`): the row's own
    /// `args` with `target` set to it.
    public func arguments(kind: String, id: String) -> AppJSON {
        var object = args?.objectValue ?? [:]
        object["target"] = ["kind": .string(kind), "id": .string(id)]
        return .object(object)
    }
}
