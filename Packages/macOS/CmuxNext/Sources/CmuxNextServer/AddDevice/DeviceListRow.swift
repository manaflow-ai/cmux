/// One row of Settings > Devices, every text localized: a device from `cmux device list`, or a
/// phone paired with this Mac.
public nonisolated struct DeviceListRow: Equatable, Sendable {
    public var id: String
    public var title: String
    /// What it may do and where it stands ("Runs your agents · Connected").
    public var subtitle: String
    /// A sentence a person can act on (an error, what it waits for), or nil.
    public var detail: String?
    /// `connected`, `offline`, `pending` or `error`.
    public var state: String
    public var removable: Bool

    public init(id: String, title: String, subtitle: String, detail: String?, state: String, removable: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.state = state
        self.removable = removable
    }
}
