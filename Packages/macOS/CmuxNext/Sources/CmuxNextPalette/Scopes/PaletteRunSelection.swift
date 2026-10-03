public import CmuxNextActions

/// Which typed command `palette.run` runs (palette-scopes.md 6.10): the
/// ref whose action is `action`, else the row's first (primary) one. A row
/// without refs is refused: its closures have no origin check.
public struct PaletteRunSelection {
    public init() {}
    public enum Failure: Error, Sendable, Equatable {
        case unknownScope
        case refused(PaletteRunRefusal)
    }

    public func pick(_ refs: [PaletteActionRef], title: String, item: String,
                            action: String?) throws(PaletteRunRefusal) -> PaletteActionRef {
        guard let first = refs.first else { throw .untyped(title: title) }
        guard let action, !action.isEmpty else { return first }
        guard let ref = refs.first(where: { $0.action.rawValue == action }) else { throw .unknownAction(item: item, action: action) }
        return ref
    }
}
