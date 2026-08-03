import AppKit
import CmuxSwiftRender

/// Native table whose rows dispatch a host reorder command after drag and drop.
@MainActor
final class ReorderableList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("com.cmux.custom-sidebar.reorder")

    private let rows: [RenderNode]
    private let spec: ReorderSpec?
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets
    private let tableView = NSTableView()

    init(
        rows: [RenderNode],
        spec: ReorderSpec?,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) {
        self.rows = rows
        self.spec = spec
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.indices.reduce(0) { $0 + rowHeight($1) })
    }

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        RenderNodeView(node: rows[row], dispatch: dispatch, contentInsets: contentInsets)
    }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight(row)
    }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (
        any NSPasteboardWriting
    )? {
        let item = NSPasteboardItem()
        item.setString(itemID(row), forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop _: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        guard let spec,
              let draggedID = info.draggingPasteboard.string(forType: Self.dragType)
        else { return false }
        let target = min(max(0, row), rows.count)
        dispatch.run(
            ButtonAction(commands: [
                .cmux(
                    method: spec.method, params: [spec.idParam: draggedID, spec.indexParam: String(target)]
                ),
            ])
        )
        return true
    }

    private func itemID(_ row: Int) -> String {
        guard let spec, spec.itemIds.indices.contains(row) else { return "row-\(row)" }
        return spec.itemIds[row]
    }

    private func rowHeight(_ row: Int) -> CGFloat {
        max(
            20,
            RenderNodeView(node: rows[row], dispatch: dispatch, contentInsets: contentInsets).fittingSize
                .height
        )
    }
}
