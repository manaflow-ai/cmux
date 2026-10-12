/// One interface an app implements (manifest v2 `implements`), the unit a
/// client mounts: a sidebar section (`cmux.section/1`), a status item
/// (`cmux.status/1`), a pane, a palette scope, a provider. A version 1
/// manifest maps its `contributes` entries onto the same shape, so the UI
/// reads one model for both.
public nonisolated struct AppImplementation: Sendable, Hashable, Identifiable {
    public static let section = "cmux.section/1"
    public static let status = "cmux.status/1"
    public static let pane = "cmux.pane/1"
    public static let paletteScope = "cmux.palette.scope/1"

    /// `cmux.section/1`.
    public var interface: String
    /// Unique within the app: the interface name (v2), or the contribution
    /// id (v1, where one app can have several sections).
    public var id: String
    public var title: AppLocalizedText?
    public var symbol: String?
    /// The script export that renders it (absent for a native pane).
    public var export: String?
    /// A pane cmux draws itself (`native`, for example `home`): no scene.
    public var native: String?
    /// `options` (v2) or the whole entry (v1): `defaultRegion`, `maxRows`, `placement`.
    public var options: [String: AppJSON]

    public init(interface: String, id: String? = nil, title: AppLocalizedText? = nil, symbol: String? = nil,
                export: String? = nil, native: String? = nil, options: [String: AppJSON] = [:]) {
        self.interface = interface
        self.id = id ?? interface
        self.title = title
        self.symbol = symbol
        self.export = export
        self.native = native
        self.options = options
    }

    public var isSection: Bool { interface == Self.section }
    public var isStatusItem: Bool { interface == Self.status }
    public var isPane: Bool { interface == Self.pane }
    /// Rendered from a scene the app host streams (not a native pane).
    public var hasScene: Bool { native == nil && export != nil }
    /// Sections and status items render as scenes the store can preview.
    public var isPreviewable: Bool { (isSection || isStatusItem) && hasScene }
    /// `defaultRegion` of a sidebar section (`middle` when absent).
    public var defaultRegion: String { options["defaultRegion"]?.stringValue ?? "middle" }
    /// `maxRows` of a sidebar section.
    public var maxRows: Int? { options["maxRows"]?.numberValue.map { Int($0) } }
}
