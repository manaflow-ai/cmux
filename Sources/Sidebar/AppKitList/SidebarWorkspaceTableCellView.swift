import AppKit
import SwiftUI

/// Reusable table cell containing exactly one SwiftUI hosting view.
@MainActor
final class SidebarWorkspaceTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceTableCellView")

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var representedRowId: SidebarWorkspaceRenderItemID?
    private var representedRow: SidebarWorkspaceTableRowConfiguration?
    private var representedPointerHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        hostingView.wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.required, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func configure(
        row: SidebarWorkspaceTableRowConfiguration,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) -> Bool {
        if let representedRow,
           representedRow.id == row.id,
           representedRow.hasEquivalentContent(to: row),
           representedPointerHovering == isPointerHovering {
            return false
        }
        representedRowId = row.id
        representedRow = row
        representedPointerHovering = isPointerHovering
        hostingView.rootView = row.makeContent(
            isPointerHovering,
            SidebarWorkspaceTableContextMenuActions(
                didOpen: contextMenuDidOpen,
                didClose: contextMenuDidClose
            )
        )
        return true
    }
}
