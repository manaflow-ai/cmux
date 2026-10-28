/// Kind-specific behavior for divider handles.
extension DividerHandleView.Kind {
    /// Id of this divider's `LayoutMouseArea`.
    var mouseAreaID: String {
        switch self {
        case .split(let id): "split:\(id.rawValue)"
        case .columnEdge(let id): "column:\(id.rawValue)"
        case .rowEdge(_, let row): "row:\(row.rawValue)"
        }
    }

    /// Whether this handle is a row separator rather than a pane divider.
    var usesRowSeparator: Bool {
        if case .rowEdge = self { return true }
        return false
    }
}
