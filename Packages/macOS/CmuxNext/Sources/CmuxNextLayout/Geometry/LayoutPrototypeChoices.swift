public import CmuxNextDesign

// Debug Settings choices of the layout model prototypes (layout-model.md).

/// Which layout model the DEV prototype draws (plans/cmux-next/layout-model.md,
/// "Prototypes"). View-only: the geometry reinterprets the current screen and
/// nothing is written to the store.
public nonisolated enum LayoutPrototypeModel: String, Sendable, CaseIterable, TunableChoice {
    /// The real layout.
    case off
    /// Design A, the frame: the right sticky column is drawn as a top or
    /// bottom dock between the side docks.
    case frameDocks
    /// Design B, the grid: each strip column's panes become cells by index,
    /// rows share one height across columns, missing cells are holes.
    case grid

    public var tunableTitle: String {
        switch self {
        case .off: "Off (real layout)"
        case .frameDocks: "A: frame with top/bottom dock"
        case .grid: "B: grid with aligned rows"
        }
    }
}

/// The edge the frame prototype docks the right sticky column to.
public nonisolated enum LayoutPrototypeDockEdge: String, Sendable, CaseIterable, TunableChoice {
    case bottom
    case top

    public var tunableTitle: String {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        }
    }
}

/// Which docks own the frame's corners (layout-model.md, decision L2).
public nonisolated enum LayoutPrototypeOrientation: String, Sendable, CaseIterable, TunableChoice {
    /// Side docks run the full height; top and bottom docks sit between them.
    case columnMajor
    /// Top and bottom docks run the full width; side docks sit between them.
    case rowMajor

    public var tunableTitle: String {
        switch self {
        case .columnMajor: "Column-major (side docks full height)"
        case .rowMajor: "Row-major (top/bottom docks full width)"
        }
    }
}
