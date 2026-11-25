public import Foundation

/// One extension status item (`cmux.status/1`) as the daemon lists it (`apps.status.list`, cmux-tui-core
/// `apps/status_items.rs`): which app draws it and where. The daemon decides; the Mac draws only these.
public nonisolated struct AppStatusItem: Sendable, Hashable, Identifiable {
    /// Where cmux NEXT draws an item (the daemon's `place`).
    public enum Place: String, Sendable, Hashable {
        /// The window's top row, after the toolbar band.
        case titlebar
        /// A row of the cmux menu bar item's menu.
        case menuBar
    }

    public var app: String
    /// The app's name.
    public var extensionName: String
    public var title: String
    public var symbol: String?
    public var place: Place

    public var id: String { app }

    /// The `apps.status.list` reply's `items`.
    public static func list(_ reply: AppJSON) -> [AppStatusItem] {
        (reply["items"]?.arrayValue ?? []).compactMap(AppStatusItem.init(json:))
    }

    public init?(json: AppJSON) {
        guard let app = json["app"]?.stringValue, let title = json["title"]?.stringValue,
              let place = json["place"]?.stringValue.flatMap(Place.init(rawValue:)) else { return nil }
        self.app = app
        self.title = title
        self.place = place
        extensionName = json["extension"]?.stringValue ?? app
        symbol = json["symbol"]?.stringValue
    }
}

extension AppsTransport {
    /// The status items of installed, enabled and visible apps (`apps.status.list`).
    public func statusItems() async throws(AppsTransportError) -> [AppStatusItem] {
        AppStatusItem.list(try await storeCall("apps.status.list"))
    }
}
