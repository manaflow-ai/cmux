public import CmuxNextDesign

/// How a floating viewer bar (look A) arranges its controls (Debug Settings `macScreen.toolbarBar`). Leo 2026-11-22,
/// of the two-row bar: "this is still bad looking". Every one-row variant keeps one 28 pt row at every width: Send Keys
/// and Refresh live in More, the Quality button says the rate or shows its glyph alone (never "Auto"), and a narrow
/// pane folds the display picker into More and truncates the name before anything wraps.
public nonisolated enum MacScreenToolbarBar: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// T1: one row. Status and name on the left, then View | Control, the rate, Full Screen, More and Disconnect.
    case row
    /// T2: one row of glyphs. View | Control as two glyphs, Disconnect as a close glyph; the name stays.
    case icons
    /// T3: the controls alone. The status dot leads, the name is the dot's tooltip; the bar hugs its controls.
    case controls
    /// Before: the name on one row, the controls wrapped under it whenever they do not fit beside it.
    case stacked

    public var tunableTitle: String {
        switch self {
        case .row: "One row (default): name, View | Control, rate, Full Screen, More, Disconnect"
        case .icons: "Glyphs: one row of icons, the name kept"
        case .controls: "Controls only: the status dot and the controls, the name in its tooltip"
        case .stacked: "Two rows (before): the controls wrap under the name"
        }
    }

    /// The bar keeps to one row.
    var oneRow: Bool { self != .stacked }
}
