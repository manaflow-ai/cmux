import AppKit
import SwiftUI

/// Recycled AppKit cell containing one stable Vault row hosting view.
@MainActor
final class SessionIndexTableCellView: NSTableCellView {
    private let hostingView = NSHostingView(
        rootView: SessionIndexTableCellRootView(
            row: .gap(beforeKey: nil, isValidDrop: true, actions: SectionGapActions(
                currentDraggedKey: { nil },
                moveSection: { _, _ in },
                clearDraggedKey: {}
            )),
            environment: .fallback
        )
    )
    private var configuredRow: SessionIndexTableRow?
    private var configuredEnvironment: SessionIndexTableEnvironmentSnapshot?

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
        if let configuredRow,
           let configuredEnvironment,
           configuredRow.hasEquivalentContent(to: row),
           configuredEnvironment.hasEquivalentPresentation(to: environment) {
            return
        }
        configuredRow = row
        configuredEnvironment = environment
        hostingView.rootView = SessionIndexTableCellRootView(
            row: row,
            environment: environment
        )
    }
}
