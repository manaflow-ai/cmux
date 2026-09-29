public import CmuxNextActions

/// One pickable object for a target argument.
public struct PaletteTargetOption: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String?

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
    }
}

/// Lists the objects of each target kind (from the daemon mirror), so the
/// palette can collect `ActionArgumentKind.target` arguments as a list.
public protocol PaletteTargetSource: AnyObject {
    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption]
}
