import AppKit
import SwiftUI

/// Recycled AppKit cell containing one stable Vault row hosting view.
@MainActor
final class SessionIndexTableCellView: NSTableCellView {
    private let model: SessionIndexTableCellModel
    private let highlightProjection = SessionIndexTableCellHighlightProjection()
    private var popoverAnchorRects: [SessionIndexTablePopoverIdentity: NSRect] = [:]
    private lazy var hostingView = NSHostingView(
        rootView: SessionIndexTableCellRootView(
            model: model,
            highlight: highlightProjection,
            onPopoverAnchorChange: { [weak self] identity, rect in
                self?.updatePopoverAnchor(identity, rect: rect)
            }
        )
    )
    var onPopoverAnchorChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        model = SessionIndexTableCellModel(
            row: .gap(beforeKey: nil, isValidDrop: true, actions: SectionGapActions(
                currentDraggedKey: { nil },
                moveSection: { _, _ in },
                clearDraggedKey: {}
            )),
            environment: .fallback
        )
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
        guard model.configure(row: row, environment: environment) else {
            return
        }
        popoverAnchorRects.removeAll()
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
        // SwiftUI's named coordinate spaces use a flipped (top-left) origin,
        // while NSTableCellView is unflipped (bottom-left). Convert through the
        // hosting view before handing the rectangle to NSPopover; passing the
        // raw SwiftUI value mirrors the row vertically and makes the preview
        // appear detached from the session that was clicked.
        let convertedRect = rect.map { hostingView.convert($0, to: self) }
        guard popoverAnchorRects[identity] != convertedRect else { return }
        popoverAnchorRects[identity] = convertedRect
        onPopoverAnchorChange?()
    }
}
