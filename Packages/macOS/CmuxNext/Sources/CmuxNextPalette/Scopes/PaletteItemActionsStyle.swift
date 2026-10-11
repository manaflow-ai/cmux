public import CmuxNextDesign

/// What Tab on a row with commands does (`palette.itemActions`).
public nonisolated enum PaletteItemActionsStyle: String, Sendable, CaseIterable, TunableChoice {
    /// The floating Actions menu, as Cmd-K.
    case menu
    /// The row's commands as a scope with a chip; Backspace returns.
    case scope

    public var tunableTitle: String {
        switch self {
        case .menu: "Menu (floating, as Cmd-K)"
        case .scope: "Scope (chip, Backspace returns)"
        }
    }
}
