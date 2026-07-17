import AppKit
import SwiftUI

/// Reusable table cell containing exactly one SwiftUI hosting view.
@MainActor
final class SidebarWorkspaceTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceTableCellView")

    let model: SidebarWorkspaceTableCellModel
    private let hostingView: SidebarWorkspaceTableHostingView

    var hostedContentSizeDidInvalidate: (() -> Void)? {
        get { hostingView.contentSizeDidInvalidate }
        set { hostingView.contentSizeDidInvalidate = newValue }
    }

    var representedRowId: SidebarWorkspaceRenderItemID? {
        model.state?.row.id
    }

    override init(frame frameRect: NSRect) {
        let model = SidebarWorkspaceTableCellModel()
        self.model = model
        self.hostingView = SidebarWorkspaceTableHostingView(
            rootView: SidebarWorkspaceTableCellRootView(model: model)
        )
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        hostingView.wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // The table owns row heights explicitly. Intrinsic sizing remains
        // enabled only as a change signal for cell-local SwiftUI expansion;
        // the controller measures on a later run-loop turn, outside rendering.
        hostingView.sizingOptions = [.intrinsicContentSize]
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
        let didReconfigure = model.configure(
            row: row,
            isPointerHovering: isPointerHovering,
            contextMenuActions: SidebarWorkspaceTableContextMenuActions(
                didOpen: contextMenuDidOpen,
                didClose: contextMenuDidClose
            )
        )
        return didReconfigure
    }

    func hostedContentHeight() -> CGFloat {
        ceil(max(1, hostingView.fittingSize.height))
    }
}
