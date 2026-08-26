import AppKit
import SwiftUI

/// Hosts SwiftUI row content inside an `NSOutlineView` cell while leaving every
/// pointer event to the outline: the display host never hit-tests, so click,
/// double-click, drag, and the context menu are handled natively. Machine rows
/// add a second, hit-testable host for their hover buttons, faded in by a
/// tracking area (the buttons are always laid out so hovering never reflows).
final class CloudTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CloudTreeCell")

    private let displayHost = CloudTreePassthroughHostingView(rootView: AnyView(EmptyView()))
    private var buttonsHost: NSHostingView<AnyView>?
    private var trackingArea: NSTrackingArea?
    private var hovered = false {
        didSet { buttonsHost?.alphaValue = hovered ? 1 : 0 }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        displayHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(displayHost)
        // The outline's `frameOfCell` already shifted this cell 2pt past the 16pt
        // disclosure slot; the remaining 4pt completes `CloudTreeRowGrid.disclosureGap`.
        // Content pads its own trailing edge (`CloudTreeRowGrid.trailingPadding`).
        NSLayoutConstraint.activate([
            displayHost.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: CloudTreeRowGrid.disclosureGap - CloudTreeNSOutlineView.cellShift
            ),
            displayHost.topAnchor.constraint(equalTo: topAnchor),
            displayHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            displayHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: CloudTreeNode, machineActions: MachineRowActions) {
        displayHost.rootView = AnyView(
            CloudTreeRowContentView(kind: node.kind)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
        if case .machine(let machine) = node.kind {
            let buttons = buttonsHost ?? makeButtonsHost()
            buttons.rootView = AnyView(CloudTreeMachineRowButtons(machine: machine, actions: machineActions))
            buttons.isHidden = false
            buttons.alphaValue = hovered ? 1 : 0
            toolTip = [machine.displayName, machine.activityLabel, machine.image].joined(separator: "\n")
        } else {
            buttonsHost?.isHidden = true
            toolTip = nil
        }
        setAccessibilityLabel(node.searchableTitle)
    }

    private func makeButtonsHost() -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CloudTreeRowGrid.trailingPadding),
            // Buttons sit on the name line, like the chevron and the status dot.
            host.topAnchor.constraint(equalTo: topAnchor, constant: CloudTreeRowGrid.machineVerticalPadding),
            displayHost.trailingAnchor.constraint(lessThanOrEqualTo: host.leadingAnchor, constant: -CloudTreeRowGrid.trailingGap),
        ])
        buttonsHost = host
        return host
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }
}

/// A hosting view that is invisible to hit testing, so the outline row beneath
/// it owns selection, drag, double-click, and the context menu.
final class CloudTreePassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Row view drawing the same selection treatment as the Files sidebar.
final class CloudTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let insetRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 4, yRadius: 4)
        (isKeyboardFocusActive ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
        path.fill()
    }

    private var isKeyboardFocusActive: Bool {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return window?.isKeyWindow == true && window?.firstResponder === outlineView
            }
            view = candidate.superview
        }
        return false
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isKeyboardFocusActive ? .emphasized : .normal
    }
}
