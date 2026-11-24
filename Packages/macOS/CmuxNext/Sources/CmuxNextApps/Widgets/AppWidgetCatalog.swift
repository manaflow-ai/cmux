/// One widget the person can place (a row of `apps.widgets.list`): an installed, enabled and
/// visible app's `cmux.widget/1`.
public nonisolated struct AppWidgetSpec: Sendable, Hashable, Identifiable {
    /// The app id.
    public var app: String
    public var title: String
    /// The sizes it draws, in the manifest's order.
    public var sizes: [AppWidgetSize]
    public var defaultSize: AppWidgetSize
    public var symbol: String?
    public var description: String?

    public var id: String { app }

    public init(app: String, title: String, sizes: [AppWidgetSize], defaultSize: AppWidgetSize,
                symbol: String? = nil, description: String? = nil) {
        self.app = app
        self.title = title
        self.sizes = sizes
        self.defaultSize = defaultSize
        self.symbol = symbol
        self.description = description
    }

    /// The sizes it draws in the sidebar (small and medium only).
    public var sidebarSizes: [AppWidgetSize] { sizes.filter(AppWidgetSize.sidebar.contains) }

    /// The size Add Widget places in the sidebar: its default when the sidebar takes it, else its
    /// first sidebar size.
    public var sidebarDefault: AppWidgetSize? {
        AppWidgetSize.sidebar.contains(defaultSize) ? defaultSize : sidebarSizes.first
    }
}

/// One placed tile of a place's layout.
public nonisolated struct AppWidgetTile: Sendable, Hashable, Identifiable {
    /// Stable for the placed tile (`w1`, `w2`, ...); the mount context's `instance`.
    public var instance: String
    public var app: String
    public var size: AppWidgetSize

    public var id: String { instance }

    public init(instance: String, app: String, size: AppWidgetSize) {
        self.instance = instance
        self.app = app
        self.size = size
    }
}

/// The `apps.widgets.list {place}` reply: the widgets the person can place there and the tiles
/// placed, in order. The daemon already leaves out tiles of apps no longer shown.
public nonisolated struct AppWidgetCatalog: Sendable, Hashable {
    public var widgets: [AppWidgetSpec]
    public var tiles: [AppWidgetTile]
    /// The layout document's revision.
    public var revision: UInt64

    public init(widgets: [AppWidgetSpec] = [], tiles: [AppWidgetTile] = [], revision: UInt64 = 0) {
        self.widgets = widgets
        self.tiles = tiles
        self.revision = revision
    }

    /// Reads the reply for `place` (`sidebar`, `newtab`). A row or tile the client cannot read is
    /// skipped; a tile with a size the client does not know is too.
    public init(reply: AppJSON, place: String) {
        widgets = (reply["widgets"]?.arrayValue ?? []).compactMap { row in
            guard let app = row["app"]?.stringValue else { return nil }
            let sizes = (row["sizes"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(AppWidgetSize.init(rawValue:)) }
            let defaultSize = row["defaultSize"]?.stringValue.flatMap(AppWidgetSize.init(rawValue:)) ?? sizes.first ?? .small
            return AppWidgetSpec(app: app, title: row["title"]?.stringValue ?? app, sizes: sizes.isEmpty ? [.small] : sizes,
                                 defaultSize: defaultSize, symbol: row["symbol"]?.stringValue,
                                 description: row["description"]?.stringValue)
        }
        let layout = reply["layout"]
        tiles = (layout?[place]?.arrayValue ?? []).compactMap { item in
            guard let instance = item["instance"]?.stringValue, let app = item["app"]?.stringValue,
                  let size = item["size"]?.stringValue.flatMap(AppWidgetSize.init(rawValue:)) else { return nil }
            return AppWidgetTile(instance: instance, app: app, size: size)
        }
        revision = layout?["revision"]?.numberValue.flatMap { UInt64(exactly: $0) } ?? 0
    }

    /// The spec of `app`'s widget, when it is still placeable.
    public func spec(_ app: String) -> AppWidgetSpec? { widgets.first { $0.app == app } }
}
