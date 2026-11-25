public import Foundation

/// One app item of the window's toolbar band (`contributes.toolbarItems`), as the daemon resolves it
/// (`apps.toolbar.list`, cmux-tui-core `apps/toolbar.rs`): only installed, enabled and visible apps'
/// buttons and menu buttons whose actions are the app's own catalog ops, in the daemon's order. The
/// Mac draws the list and runs a click's op through `apps-run` as the person; it decides nothing.
public nonisolated struct AppToolbarContribution: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Runs `op`.
        case button
        /// Opens `entries`.
        case menu
    }

    public struct Entry: Sendable, Hashable {
        public var title: AppLocalizedText
        public var op: String
        public var args: AppJSON
    }

    public var app: String
    /// The app's name: the tooltip names it as the button's source.
    public var extensionName: String
    public var itemID: String
    public var kind: Kind
    public var title: AppLocalizedText
    /// An SF Symbol name.
    public var symbol: String?
    /// A package-relative image path (read from the app's bundle directory).
    public var iconPath: String?
    public var op: String?
    public var args: AppJSON
    public var entries: [Entry]

    public var id: String { "\(app)#\(itemID)" }

    /// The `apps.toolbar.list` reply's `items`.
    public static func list(_ reply: AppJSON) -> [AppToolbarContribution] {
        (reply["items"]?.arrayValue ?? []).compactMap(AppToolbarContribution.init(json:))
    }

    public init?(json: AppJSON) {
        guard let app = json["app"]?.stringValue, let itemID = json["id"]?.stringValue,
              let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let title = AppLocalizedText(json: json["title"]) else { return nil }
        self.app = app
        self.itemID = itemID
        self.kind = kind
        self.title = title
        extensionName = json["extension"]?.stringValue ?? app
        symbol = json["symbol"]?.stringValue
        iconPath = json["icon"]?.stringValue
        op = json["op"]?.stringValue
        args = json["args"] ?? .object([:])
        entries = (json["entries"]?.arrayValue ?? []).compactMap { entry in
            guard let title = AppLocalizedText(json: entry["title"]), let op = entry["op"]?.stringValue else { return nil }
            return Entry(title: title, op: op, args: entry["args"] ?? .object([:]))
        }
        if kind == .button, op == nil { return nil }
        if kind == .menu, entries.isEmpty { return nil }
    }
}
