/// Per-window sizing introspection for `remote.tmux.pane_grids`, the Sendable
/// transfer twin of the app-side `RemoteTmuxWindowMirror.SizingSnapshot`.
public struct ControlRemoteTmuxSizingSnapshot: Sendable, Equatable {
    public struct Pane: Sendable, Equatable {
        public let paneId: Int
        public let assignedColumns: Int
        public let assignedRows: Int
        public let renderedColumns: Int?
        public let renderedRows: Int?
        public let exactColumns: Bool
        public let exactRows: Bool
        public let hasPanel: Bool
        public let viewInWindow: Bool?
        public let surfaceLive: Bool?
        public let calibration: Calibration?

        public init(
            paneId: Int,
            assignedColumns: Int,
            assignedRows: Int,
            renderedColumns: Int?,
            renderedRows: Int?,
            exactColumns: Bool,
            exactRows: Bool,
            hasPanel: Bool,
            viewInWindow: Bool?,
            surfaceLive: Bool?,
            calibration: Calibration?
        ) {
            self.paneId = paneId
            self.assignedColumns = assignedColumns
            self.assignedRows = assignedRows
            self.renderedColumns = renderedColumns
            self.renderedRows = renderedRows
            self.exactColumns = exactColumns
            self.exactRows = exactRows
            self.hasPanel = hasPanel
            self.viewInWindow = viewInWindow
            self.surfaceLive = surfaceLive
            self.calibration = calibration
        }
    }

    public struct Calibration: Sendable, Equatable {
        public let columns: Int
        public let rows: Int
        public let cellWidthPx: Int
        public let cellHeightPx: Int
        public let surfaceWidthPx: Int
        public let surfaceHeightPx: Int
        public let viewWidthPt: Double?
        public let viewHeightPt: Double?
        public let backingScale: Double?

        public init(
            columns: Int,
            rows: Int,
            cellWidthPx: Int,
            cellHeightPx: Int,
            surfaceWidthPx: Int,
            surfaceHeightPx: Int,
            viewWidthPt: Double?,
            viewHeightPt: Double?,
            backingScale: Double?
        ) {
            self.columns = columns
            self.rows = rows
            self.cellWidthPx = cellWidthPx
            self.cellHeightPx = cellHeightPx
            self.surfaceWidthPx = surfaceWidthPx
            self.surfaceHeightPx = surfaceHeightPx
            self.viewWidthPt = viewWidthPt
            self.viewHeightPt = viewHeightPt
            self.backingScale = backingScale
        }
    }

    public let windowId: Int
    public let panes: [Pane]
    public let baseColumns: Int
    public let baseRows: Int
    public let pushedColumns: Int?
    public let pushedRows: Int?
    public let zoomed: Bool
    public let structureVersion: Int
    public let visibleForSizing: Bool
    public let containerWidthPt: Double?
    public let containerHeightPt: Double?
    public let currentFColumns: Int?
    public let currentFRows: Int?

    public init(
        windowId: Int,
        panes: [Pane],
        baseColumns: Int,
        baseRows: Int,
        pushedColumns: Int?,
        pushedRows: Int?,
        zoomed: Bool,
        structureVersion: Int,
        visibleForSizing: Bool,
        containerWidthPt: Double?,
        containerHeightPt: Double?,
        currentFColumns: Int?,
        currentFRows: Int?
    ) {
        self.windowId = windowId
        self.panes = panes
        self.baseColumns = baseColumns
        self.baseRows = baseRows
        self.pushedColumns = pushedColumns
        self.pushedRows = pushedRows
        self.zoomed = zoomed
        self.structureVersion = structureVersion
        self.visibleForSizing = visibleForSizing
        self.containerWidthPt = containerWidthPt
        self.containerHeightPt = containerHeightPt
        self.currentFColumns = currentFColumns
        self.currentFRows = currentFRows
    }
}
