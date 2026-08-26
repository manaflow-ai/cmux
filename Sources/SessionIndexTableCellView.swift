import AppKit
import SwiftUI

/// Recycled AppKit cell containing one stable Vault row hosting view.
@MainActor
final class SessionIndexTableCellView: NSTableCellView {
    private let highlightProjection = SessionIndexTableCellHighlightProjection()
    private var popoverAnchorRects: [SessionIndexTablePopoverIdentity: NSRect] = [:]
    private lazy var hostingView = NSHostingView(
        rootView: SessionIndexTableCellRootView(
            row: .gap(beforeKey: nil, isValidDrop: true, actions: SectionGapActions(
                currentDraggedKey: { nil },
                moveSection: { _, _ in },
                clearDraggedKey: {}
            )),
            environment: .fallback,
            highlight: highlightProjection,
            onPopoverAnchorChange: { [weak self] identity, rect in
                self?.updatePopoverAnchor(identity, rect: rect)
            }
        )
    )
    private var configuredRow: SessionIndexTableRow?
    private var configuredEnvironment: SessionIndexTableEnvironmentSnapshot?
    var onPopoverAnchorChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hostingView.wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // The controller owns row heights, so visible cells never negotiate
        // intrinsic SwiftUI size during an AppKit table layout pass.
        hostingView.sizingOptions = []
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        highlightProjection.sync(from: row)
        if let configuredRow,
           let configuredEnvironment,
           configuredRow.hasEquivalentContent(to: row),
           configuredEnvironment.hasEquivalentPresentation(to: environment) {
            return
        }
        popoverAnchorRects.removeAll()
        configuredRow = row
        configuredEnvironment = environment
        hostingView.rootView = SessionIndexTableCellRootView(
            row: row,
            environment: environment,
            highlight: highlightProjection,
            onPopoverAnchorChange: { [weak self] identity, rect in
                self?.updatePopoverAnchor(identity, rect: rect)
            }
        )
    }

    func updatePresentation(from row: SessionIndexTableRow) {
        highlightProjection.sync(from: row)
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
