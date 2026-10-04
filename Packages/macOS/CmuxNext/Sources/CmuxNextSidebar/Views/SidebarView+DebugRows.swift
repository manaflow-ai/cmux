public import AppKit

/// One drawn workspace-list row, for `debug.sidebar_rows`: what the list
/// shows and what its view draws (frame, alpha, in the list or not).
public struct SidebarDebugRow: Sendable {
    public var key: String
    public var title: String?
    public var frame: CGRect
    public var viewFrame: CGRect?
    public var viewAlpha: CGFloat?
    public var inList: Bool
    public var suppressed: Bool
}

extension SidebarView {
    /// The list's rows and their views, the selection and the drag (debug).
    public func debugRows() -> (rows: [SidebarDebugRow], selection: [String], dragging: [String]) {
        let rows = list.displayed.rows.map { row -> SidebarDebugRow in
            let view = list.rowViews[row.key]
            var title: String?
            if case let .workspace(id) = row.key { title = model.workspace(id)?.title }
            return SidebarDebugRow(key: String(describing: row.key), title: title, frame: list.frame(for: row),
                                   viewFrame: view?.frame, viewAlpha: view?.alphaValue, inList: view?.superview === list,
                                   suppressed: list.suppressed.contains(row.key))
        }
        let selection = model.orderedSelection.map { model.workspace($0)?.title ?? $0.rawValue }
        let dragging = list.drag.map { drag in drag.hiddenKeys.map { String(describing: $0) } } ?? []
        return (rows, selection, dragging)
    }
}
