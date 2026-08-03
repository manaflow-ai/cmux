import AppKit

/// Reusable native fallback cell used only for defensive or test rows.
@MainActor
final class SidebarWorkspaceTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceTableCellView")

    private let model: SidebarWorkspaceTableCellModel
    private let rootView: SidebarWorkspaceTableCellRootView

#if DEBUG
    var reconfigurationProbe: (() -> Void)?
    var rootViewIdentity: ObjectIdentifier { ObjectIdentifier(rootView) }
#endif

    var representedRowId: SidebarWorkspaceRenderItemID? {
        model.state?.row.id
    }

    override init(frame frameRect: NSRect) {
        let model = SidebarWorkspaceTableCellModel()
        self.model = model
        self.rootView = SidebarWorkspaceTableCellRootView()
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        rootView.wantsLayer = true
        rootView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootView.topAnchor.constraint(equalTo: topAnchor),
            rootView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearRetainedPayload()
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

    func clearRetainedPayload() {
        model.clear()
    }
}
