import CmuxCloud
import AppKit
import SwiftUI

/// Hosts SwiftUI row content inside an `NSOutlineView` cell while leaving every
/// pointer event to the outline: the display host never hit-tests, so click,
/// double-click, drag, and the context menu are handled natively. Machine rows
/// add a second, hit-testable host for their hover buttons, faded in by a
/// tracking area (the buttons are always laid out so hovering never reflows).
final class CloudTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CloudTreeCell")
    var machineReorderAccessibilityActions: (() -> [NSAccessibilityCustomAction])?

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        machineReorderAccessibilityActions?() ?? super.accessibilityCustomActions()
    }

    private let displayHost = CloudTreePassthroughHostingView(rootView: AnyView(EmptyView()))
    private var portsStatus: CloudPortsStatusContent?
    private var portsStatusTrailingConstraint: NSLayoutConstraint?
    private var buttonsHost: CloudTreeRowControlsHostingView?
    private var buttonsTrailingConstraint: NSLayoutConstraint?
    private var buttonsLeadingConstraint: NSLayoutConstraint?
    private var buttonsTopConstraint: NSLayoutConstraint?
    private var buttonsCenterConstraint: NSLayoutConstraint?
    private var hovered = false {
        didSet { buttonsHost?.alphaValue = hovered || keepsControlsVisible ? 1 : 0 }
    }
    private var keepsControlsVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        displayHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(displayHost)
        // The outline owns the complete disclosure slot and gap. The hosted
        // content starts at the cell edge, with no second horizontal offset.
        // Content pads its own trailing edge (`style.rowGrid.trailingPadding`).
        NSLayoutConstraint.activate([
            displayHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            displayHost.topAnchor.constraint(equalTo: topAnchor),
            displayHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let trailing = displayHost.trailingAnchor.constraint(equalTo: trailingAnchor)
        // Hover controls own the last few points on machine rows. Keeping this
        // just below required lets their stronger constraint win while making
        // every other row fill the cell's actual visible width.
        trailing.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.required.rawValue - 1)
        trailing.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rehosts one immutable tree snapshot and its optional row actions.
    ///
    /// - Parameters:
    ///   - node: The row snapshot to display.
    ///   - machineActions: Actions for machine and creation controls.
    ///   - nodeActions: Actions for workspace and surface controls.
    ///   - style: The visual preset for the row.
    func configure(
        node: CloudTreeNode,
        machineActions: MachineRowActions,
        nodeActions: CloudTreeNodeActions,
        style: CloudTreeStyle = CloudTreeStyleStore.current,
        portAction: @escaping @MainActor (CloudPortsStatusAction, SurfaceMachineID) -> Void = { _, _ in }
    ) {
        #if DEBUG
        if case .terminal(let row) = node.kind, row.hasUnreadNotification {
            cmuxDebugLog("cloudTree.cell.configure unread terminal=\(row.resource.id.key.suffix(4)) node=\(node.id.suffix(12))")
        }
        #endif
        let status: CloudPortsStatusPresentation? = {
            guard case .placeholder(_, let placeholder) = node.kind else { return nil }
            return placeholder.portStatus
        }()
        displayHost.isHidden = status != nil
        displayHost.rootView = AnyView(
            CloudTreeRowContentView(kind: node.kind, style: style,
                openVPNSetup: { portAction(.setupVPN, node.machine) })
                .modifier(CloudSidebarRowDecoration(
                    isPinned: node.isPinned,
                    showsAttentionSlot: node.showsAttentionSlot,
                    hasUnreadNotification: node.hasUnreadAttention,
                    attentionSlot: style.rowGrid.attentionSlot
                ))
                .frame(maxWidth: .infinity, alignment: .leading)
        )
        if let status {
            let view = portsStatus ?? makePortsStatus(style: style)
            view.isHidden = false
            view.configure(presentation: status, style: style) {
                portAction(status.action, node.machine)
            }
            portsStatusTrailingConstraint?.constant = -style.rowGrid.trailingPadding
        } else {
            portsStatus?.isHidden = true
        }
        // An in-place row reload reuses this cell; the new content can be wider
        // than the last fitting size, so ask AppKit to re-measure the host.
        displayHost.invalidateIntrinsicContentSize()
        needsLayout = true
        if case .devicesSection = node.kind { keepsControlsVisible = true }
        else { keepsControlsVisible = false }
        if CloudTreeRowHoverButtons.hasButtons(for: node.kind) {
            let buttons = buttonsHost ?? makeButtonsHost(style: style)
            buttons.rootView = AnyView(CloudTreeRowHoverButtons(kind: node.kind, machineActions: machineActions, nodeActions: nodeActions))
            buttons.isHidden = false
            buttons.alphaValue = hovered || keepsControlsVisible ? 1 : 0
            buttonsLeadingConstraint?.constant = -style.rowGrid.trailingGap
            buttonsTrailingConstraint?.constant = -style.rowGrid.trailingPadding
            buttonsLeadingConstraint?.isActive = true
            // Keep hover buttons on the name line above the resource summary.
            // Local and pending rows retain their preset alignment.
            let pinToNameLine = node.isMachineRow && (style.machineRowLayout == .twoLine || node.structureTag == "machine")
            buttonsTopConstraint?.constant = style.machineVerticalPadding + (style.machineBand ? 4 : 0)
            buttonsTopConstraint?.isActive = pinToNameLine
            buttonsCenterConstraint?.isActive = !pinToNameLine
        } else {
            buttonsHost?.isHidden = true
            buttonsLeadingConstraint?.isActive = false
        }
        if case .machine(let machine, _) = node.kind {
            toolTip = CloudTreeMachineRowContent(machine: machine).toolTip
        } else if case .pendingMachine(let operation) = node.kind {
            // The failure's first line rides along so a red row explains itself on hover.
            toolTip = operation.summaryLine
        } else if case .localMachine(let row) = node.kind {
            toolTip = row.name
        } else if case .device(let row) = node.kind {
            // Full status and counts: the row itself carries only a dim fact.
            toolTip = CloudTreeDeviceRowContent(row: row, style: style).toolTip
        } else {
            toolTip = nil
        }
        if case .machine(let machine, _) = node.kind {
            setAccessibilityLabel(CloudTreeMachineRowContent(machine: machine).accessibilityLabel)
        } else if case .device(let row) = node.kind {
            setAccessibilityLabel(CloudTreeDeviceRowContent(row: row, style: style).accessibilityLabel)
        } else if case .resource(_, let row) = node.kind {
            setAccessibilityLabel(row.accessibilityLabel)
        } else if case .terminal(let row) = node.kind {
            setAccessibilityLabel(CloudTreeTerminalRowContent(row: row, style: style).toolTip)
        } else if case .display(let resource, _, _) = node.kind {
            setAccessibilityLabel([node.searchableTitle, CloudTreeRowContentView.text(for: resource)].joined(separator: ", "))
        } else if case .port(let resource, _, _) = node.kind {
            setAccessibilityLabel([node.searchableTitle, resource.detail ?? CloudPortsStatusPresentation.routeNote].joined(separator: ", "))
        } else if let status {
            setAccessibilityLabel("\(status.title), \(status.message)")
        } else {
            setAccessibilityLabel(node.searchableTitle)
        }
    }

    private func makeButtonsHost(style: CloudTreeStyle) -> CloudTreeRowControlsHostingView {
        let host = CloudTreeRowControlsHostingView(rootView: AnyView(EmptyView()))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        // Buttons sit on the name line (two-line machine cards), like the chevron
        // and the status dot; every other row activates the center constraint.
        let top = host.topAnchor.constraint(equalTo: topAnchor, constant: style.machineVerticalPadding)
        let center = host.centerYAnchor.constraint(equalTo: centerYAnchor)
        let trailing = host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.rowGrid.trailingPadding)
        buttonsTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            trailing,
            top,
        ])
        buttonsLeadingConstraint = displayHost.trailingAnchor.constraint(
            lessThanOrEqualTo: host.leadingAnchor,
            constant: -style.rowGrid.trailingGap
        )
        buttonsTopConstraint = top
        buttonsCenterConstraint = center
        buttonsHost = host
        return host
    }

    private func makePortsStatus(style: CloudTreeStyle) -> CloudPortsStatusContent {
        let view = CloudPortsStatusContent(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let trailing = view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.rowGrid.trailingPadding)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        portsStatusTrailingConstraint = trailing
        portsStatus = view
        return view
    }

    func setHovered(_ hovered: Bool) {
        guard self.hovered != hovered else { return }
        self.hovered = hovered
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        machineReorderAccessibilityActions = nil
        hovered = false
        portsStatus?.isHidden = true
    }
}

/// Ordinary content leaves events to the outline; the native VPN help button
/// retains its own click, keyboard, and accessibility action.
final class CloudTreePassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit owns coordinate conversion; only the native help control
        // intercepts a hit. Labels still leave selection and expansion to the outline.
        guard let hit = super.hitTest(point), hit is CloudVPNHelpButton else { return nil }
        return hit
    }
}

/// The hit-testable host for a row's hover buttons. `CloudTreeNSOutlineView`
/// hands mouse-downs inside it to SwiftUI; NSTableView otherwise keeps every
/// click on a non-`NSControl` subview and runs the row's own click action.
final class CloudTreeRowControlsHostingView: NSHostingView<AnyView> {}

/// Row view drawing the same selection treatment as the Files sidebar.
final class CloudTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let insetRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 4, yRadius: 4)
        // Gray in both focus states (no accent blue); keyboard focus reads as a
        // slightly stronger shade.
        NSColor.labelColor.withAlphaComponent(isKeyboardFocusActive ? 0.12 : 0.07).setFill()
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
        // The gray highlight keeps normal label colors; .emphasized would flip
        // the text to white as if on an accent fill.
        .normal
    }
}
