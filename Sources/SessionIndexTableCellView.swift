import AppKit

/// Recycled AppKit cell containing one stable native Vault row root.
@MainActor
final class SessionIndexTableCellView: NSTableCellView {
    private var popoverAnchorRects: [SessionIndexTablePopoverIdentity: NSRect] = [:]
    private let rootView = SessionIndexTableCellRootView()
    private var configuredRow: SessionIndexTableRow?
    private var configuredEnvironment: SessionIndexTableEnvironmentSnapshot?
    var onPopoverAnchorChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row: SessionIndexTableRow,
        environment: SessionIndexTableEnvironmentSnapshot
    ) {
        rootView.updatePresentation(from: row)
        if let configuredRow,
           let configuredEnvironment,
           configuredRow.hasEquivalentContent(to: row),
           configuredEnvironment.hasEquivalentPresentation(to: environment) {
            return
        }
        popoverAnchorRects.removeAll()
        configuredRow = row
        configuredEnvironment = environment
        rootView.configure(
            row: row,
            environment: environment,
            onPopoverAnchorChange: { [weak self] identity, rect in
                self?.updatePopoverAnchor(identity, rect: rect)
            }
        )
    }

    func updatePresentation(from row: SessionIndexTableRow) {
        rootView.updatePresentation(from: row)
    }

    func popoverAnchorRect(for identity: SessionIndexTablePopoverIdentity) -> NSRect? {
        popoverAnchorRects[identity]
    }

    private func updatePopoverAnchor(
        _ identity: SessionIndexTablePopoverIdentity,
        rect: CGRect?
    ) {
        guard popoverAnchorRects[identity] != rect else { return }
        popoverAnchorRects[identity] = rect
        onPopoverAnchorChange?()
    }
}
