public import CmuxNextActions
public import CmuxNextDesign

/// One pickable object for a target argument.
public struct PaletteTargetOption: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    /// Real colors drawn in the icon place (a theme's strip, R98).
    public var swatches: [ThemeRGB]

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, swatches: [ThemeRGB] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.swatches = swatches
    }
}

/// Lists the objects of each target kind (from the daemon mirror), so the
/// palette can collect `ActionArgumentKind.target` arguments as a list.
public protocol PaletteTargetSource: AnyObject {
    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption]
    /// The object's own name, which a rename prompt starts from; nil when
    /// it has none (an untitled object shows a fallback label instead).
    func title(of target: ActionTargetRef) -> String?
}

extension PaletteTargetSource {
    /// The listed title of `target`, for sources whose listed titles are
    /// all real names.
    public func title(of target: ActionTargetRef) -> String? {
        targets(of: target.kind).first { $0.id == target.id }?.title
    }
}
