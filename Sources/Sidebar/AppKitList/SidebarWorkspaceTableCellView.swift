import AppKit
import SwiftUI

/// Reusable table cell containing exactly one SwiftUI hosting view.
@MainActor
final class SidebarWorkspaceTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceTableCellView")

    private let model: SidebarWorkspaceTableCellModel
    private let hostingView: NSHostingView<SidebarWorkspaceTableCellRootView>

#if DEBUG
    var reconfigurationProbe: (() -> Void)?
    var hostingViewIdentity: ObjectIdentifier { ObjectIdentifier(hostingView) }
    var hostedRootIdentity: UUID { hostingView.rootView.identity }
#endif

    var representedRowId: SidebarWorkspaceRenderItemID? {
        model.state?.row.id
    }

    override init(frame frameRect: NSRect) {
        let model = SidebarWorkspaceTableCellModel()
        self.model = model
        self.hostingView = NSHostingView(
            rootView: SidebarWorkspaceTableCellRootView(
                identity: UUID(),
                model: model
            )
        )
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
        let didReconfigure = model.configure(
            row: row,
            isPointerHovering: isPointerHovering,
            contextMenuActions: SidebarWorkspaceTableContextMenuActions(
                didOpen: contextMenuDidOpen,
                didClose: contextMenuDidClose
            )
        )
#if DEBUG
        if didReconfigure {
            reconfigurationProbe?()
        }
#endif
        return didReconfigure
    }
}
