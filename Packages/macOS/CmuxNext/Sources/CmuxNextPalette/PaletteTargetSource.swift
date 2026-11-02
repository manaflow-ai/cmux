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
    /// False keeps an unavailable destination visible but prevents choosing it.
    public var isEnabled: Bool

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, swatches: [ThemeRGB] = [], isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.swatches = swatches
        self.isEnabled = isEnabled
    }
}

/// Lists the objects of each target kind (from the daemon mirror), so the
/// palette can collect `ActionArgumentKind.target` arguments as a list.
public protocol PaletteTargetSource: AnyObject {
    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption]
    /// The objects `action` picks for an argument of `kind`: the kind's
    /// whole list unless the action takes only some of them (Reopen Saved
    /// Tab Group… lists saved groups, not open ones).
    func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption]
    /// An optional live inventory read when the argument page opens. Its cached rows may draw
    /// immediately; the palette's existing provider task is cancelled when the page closes.
    func targetRefresh(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () async -> [PaletteTargetOption])?
    /// A live inventory that comes over time (a first list, then a fuller one); nil: `targetRefresh` once.
    func targetUpdates(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () -> AsyncStream<[PaletteTargetOption]>)?
    /// The object's own name, which a rename prompt starts from; nil when
    /// it has none (an untitled object shows a fallback label instead).
    func title(of target: ActionTargetRef) -> String?
    /// The object's current description, which an edit prompt starts from;
    /// nil when it has none or its kind carries none.
    func currentDescription(of target: ActionTargetRef) -> String?
}

extension PaletteTargetSource {
    public func targetRefresh(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () async -> [PaletteTargetOption])? { nil }
    public func targetUpdates(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () -> AsyncStream<[PaletteTargetOption]>)? { nil }

    /// The kind's whole list, for sources no action narrows.
    public func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption] {
        targets(of: kind)
    }

    /// The listed title of `target`, for sources whose listed titles are
    /// all real names.
    public func title(of target: ActionTargetRef) -> String? {
        targets(of: target.kind).first { $0.id == target.id }?.title
    }

    /// No description, for sources whose objects carry none.
    public func currentDescription(of target: ActionTargetRef) -> String? { nil }
}
