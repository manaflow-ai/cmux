public import AppKit

/// One drawn workspace-list row, for `debug.sidebar_rows`: what the list
/// shows and what its view draws (frame, alpha, in the list or not).
public struct SidebarDebugRow: Sendable {
    public var key: String
    public var title: String?
    public var frame: CGRect
    /// The row in window points from the top-left (as `debug.mouse` takes them).
    public var windowFrame: CGRect
    public var viewFrame: CGRect?
    public var viewAlpha: CGFloat?
    public var inList: Bool
    public var suppressed: Bool
}

/// One sidebar layout item (a top or bottom region row), for
/// `debug.sidebar_rows`: what it points at, whether it is active, and where
/// its view is (nil while it draws nothing).
public struct SidebarDebugItem: Sendable {
    public var id: String
    public var refKind: String
    public var ref: String
    public var region: String
    public var isActive: Bool
    /// The item in window points from the top-left (as `debug.mouse` takes them).
    public var windowFrame: CGRect?
}

/// One drop resolution of an internal drag, for `debug.sidebar_rows`.
public struct SidebarDropProbe: Sendable, Equatable {
    /// `top` or `bottom`: the card's leading edge for the drag direction.
    public var edge: String
    /// The edge in list coordinates as drawn, and in the base layout.
    public var displayY: CGFloat
    public var baseY: CGFloat?
    /// The base-layout row under the edge and the edge's share of its height.
    public var row: String?
    public var fraction: CGFloat?
    /// The resolved target, or nil when the drop is refused.
    public var target: String?
}

extension SidebarView {
    /// Every layout item of the shown sections and its view (debug).
    public func debugLayoutItems() -> [SidebarDebugItem] {
        let height = window?.contentView?.bounds.height ?? 0
        return model.layout.sections.flatMap { section in
            section.items.map { item -> SidebarDebugItem in
                var frame: CGRect?
                for region in [aboveRegion, belowRegion] {
                    guard let view = region.itemView(item.id), view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
                    let inWindow = view.convert(view.bounds, to: nil)
                    frame = CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
                }
                return SidebarDebugItem(id: item.id.rawValue, refKind: item.ref.kind, ref: item.ref.value, region: section.region.rawValue,
                                        isActive: model.itemInfo[item.id]?.isActive == true, windowFrame: frame)
            }
        }
    }

    /// The list's rows and their views, the selection and the drag (debug).
    /// The drag's last drop probe (debug): nil while nothing is dragged.
    public func debugDropProbe() -> SidebarDropProbe? { list.drag?.probe }

    public func debugRows() -> (rows: [SidebarDebugRow], selection: [String], dragging: [String]) {
        let rows = list.displayed.rows.map { row -> SidebarDebugRow in
            let view = list.rowViews[row.key]
            var title: String?
            if case let .workspace(id) = row.key { title = model.workspace(id)?.title }
            let inWindow = list.convert(list.frame(for: row), to: nil)
            let height = window?.contentView?.bounds.height ?? 0
            let windowFrame = CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            return SidebarDebugRow(key: String(describing: row.key), title: title, frame: list.frame(for: row), windowFrame: windowFrame,
                                   viewFrame: view?.frame, viewAlpha: view?.alphaValue, inList: view?.superview === list,
                                   suppressed: list.suppressed.contains(row.key))
        }
        let selection = model.orderedSelection.map { model.workspace($0)?.title ?? $0.rawValue }
        let dragging = list.drag.map { drag in drag.hiddenKeys.map { String(describing: $0) } } ?? []
        return (rows, selection, dragging)
    }

    /// The swipe pages now (debug.sidebar_rows): where each sits and what it draws.
    public func debugPaging() -> [String: String] {
        var info: [String: String] = [:]
        func describe(_ view: NSView?) -> String {
            guard let view else { return "none" }
            let tx = (view.layer?.presentation() ?? view.layer)?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
            return "super=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil") frame=\(view.frame) tx=\(tx) hidden=\(view.isHiddenOrHasHiddenAncestor) alpha=\(view.alphaValue)"
        }
        info["page"] = describe(scrollView)
        if let neighbor = spacePaging.neighbor {
            info["neighbor"] = describe(neighbor.view)
            info["neighbor_rows"] = "\(neighbor.list.displayed.rows.count) views=\(neighbor.list.rowViews.count) frame=\(neighbor.list.frame)"
        }
        info["snapshot"] = describe(spacePaging.snapshotView)
        return info
    }
}
