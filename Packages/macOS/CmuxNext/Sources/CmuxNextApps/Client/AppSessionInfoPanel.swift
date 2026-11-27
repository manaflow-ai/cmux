public import Foundation

/// A visible app contribution that can be mounted inside Session Info.
public nonisolated struct AppSessionInfoPanel: Sendable, Hashable, Identifiable {
    public var app: String
    public var section: String
    public var title: String
    public var symbol: String?
    public var maxRows: Int?

    public var id: String { "\(app)#\(section)" }

    /// The `apps.panels.list` reply's `panels`.
    public static func list(_ reply: AppJSON) -> [AppSessionInfoPanel] {
        (reply["panels"]?.arrayValue ?? []).compactMap(AppSessionInfoPanel.init(json:))
    }

    public init?(json: AppJSON) {
        guard let app = json["app"]?.stringValue,
              let section = json["section"]?.stringValue,
              let title = json["title"]?.stringValue else { return nil }
        self.app = app
        self.section = section
        self.title = title
        symbol = json["symbol"]?.stringValue
        maxRows = json["maxRows"]?.numberValue.flatMap(Int.init(exactly:))
    }
}
