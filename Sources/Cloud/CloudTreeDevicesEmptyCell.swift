import CmuxCloud
import AppKit
import SwiftUI

/// Unlike display-only outline rows, this host accepts clicks on its buttons.
final class CloudTreeDevicesEmptyCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CloudTreeDevicesEmptyCell")
    private let host = CloudTreeRowControlsHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(section: CloudTreeDevicesSection, actions: CloudTreeNodeActions, style: CloudTreeStyle, level: Int) {
        let inset = CloudTreeNSOutlineView.leadingMargin + CGFloat(max(0, level)) * style.indentPerLevel
            + style.rowGrid.disclosureSlot + style.rowGrid.disclosureGap
        host.rootView = AnyView(CloudTreeDevicesEmptyView(section: section, actions: actions, style: style, contentInset: inset))
        host.invalidateIntrinsicContentSize()
    }
}
