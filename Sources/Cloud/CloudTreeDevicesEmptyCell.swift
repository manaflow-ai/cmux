import AppKit
import SwiftUI

/// Unlike display-only outline rows, this host accepts clicks on its buttons.
final class CloudTreeDevicesEmptyCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CloudTreeDevicesEmptyCell")
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CloudTreeRowGrid.disclosureGap - CloudTreeNSOutlineView.cellShift),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(section: CloudTreeDevicesSection, actions: CloudTreeNodeActions) {
        host.rootView = AnyView(CloudTreeDevicesEmptyView(section: section, actions: actions))
        host.invalidateIntrinsicContentSize()
    }
}
