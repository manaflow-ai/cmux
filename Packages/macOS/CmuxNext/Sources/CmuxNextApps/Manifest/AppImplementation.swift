/// One interface an app implements (manifest v2 `implements`), the unit a
/// client mounts: a sidebar section (`cmux.section/1`), a status item
/// (`cmux.status/1`), a pane, a palette scope, a provider. A version 1
/// manifest maps its `contributes` entries onto the same shape, so the UI
/// reads one model for both until the samples move to version 2.
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

    public init(interface: String, id: String? = nil, title: AppLocalizedText? = nil, symbol: String? = nil) {
        self.interface = interface
        self.id = id ?? interface
        self.title = title
        self.symbol = symbol
    }

    public var isSection: Bool { interface == Self.section }
    public var isStatusItem: Bool { interface == Self.status }
    /// Sections and status items render as scenes the store can preview.
    public var isPreviewable: Bool { isSection || isStatusItem }
}
