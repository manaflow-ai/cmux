import CmuxCloud
import AppKit
import CMUXMobileCore
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import SwiftUI

/// Hosts SwiftUI row content inside an `NSOutlineView` cell while leaving every
/// pointer event to the outline: the display host never hit-tests, so click,
/// double-click, drag, and the context menu are handled natively. Machine rows
/// add a second, hit-testable host for their hover buttons, faded in by a
/// tracking area (the buttons are always laid out so hovering never reflows).
final class CloudTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CloudTreeCell")
    var machineReorderAccessibilityActions: (() -> [NSAccessibilityCustomAction])?
    private var configuredNode: CloudTreeNode?
    private var configuredStyle = CloudTreeStyleStore.current
    private let presenceObserverID = UUID()
    private let collaborators: @MainActor (SurfaceMachineID, String) -> [WorkspacePresenceParticipant]

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        machineReorderAccessibilityActions?() ?? super.accessibilityCustomActions()
    }

    private let displayHost = CloudTreePassthroughHostingView(rootView: AnyView(EmptyView()))
    private var buttonsHost: CloudTreeRowControlsHostingView?
    private var buttonsTrailingConstraint: NSLayoutConstraint?
    private var buttonsLeadingConstraint: NSLayoutConstraint?
    private var buttonsTopConstraint: NSLayoutConstraint?
    private var buttonsCenterConstraint: NSLayoutConstraint?
    private var hovered = false {
        didSet { buttonsHost?.alphaValue = hovered || keepsControlsVisible ? 1 : 0 }
    }
    private var keepsControlsVisible = false

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, collaborators: { machine, workspaceID in
            AppDelegate.shared?.workspacePresenceController.collaborators(forCloudMachine: machine, workspaceID: workspaceID) ?? []
        })
    }

    init(frame frameRect: NSRect, collaborators: @escaping @MainActor (SurfaceMachineID, String) -> [WorkspacePresenceParticipant]) {
        self.collaborators = collaborators
        super.init(frame: frameRect)
        identifier = Self.identifier
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspacePresenceDidChange(_:)),
            name: .workspacePresenceDidChange,
            object: nil
        )
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

    deinit {
        NotificationCenter.default.removeObserver(self)
        let owner = presenceObserverID
        Task { @MainActor in
            AppDelegate.shared?.workspacePresenceController.observeCloudWorkspace(machine: nil, workspaceID: nil, owner: owner)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePresenceSubscription()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePresenceSubscription()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePresenceSubscription()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePresenceSubscription()
    }

    private func updatePresenceSubscription() {
        let controller = AppDelegate.shared?.workspacePresenceController
        if window != nil, superview != nil, !isHiddenOrHasHiddenAncestor,
           let configuredNode, case .workspace(let machine, let workspace, _, _, _) = configuredNode.kind {
            controller?.observeCloudWorkspace(machine: machine, workspaceID: workspace.id, owner: presenceObserverID)
            configureDisplayHost(node: configuredNode, style: configuredStyle)
        } else {
            controller?.observeCloudWorkspace(machine: nil, workspaceID: nil, owner: presenceObserverID)
        }
    }

    @objc private func workspacePresenceDidChange(_ notification: Notification) {
        guard let configuredNode, case .workspace = configuredNode.kind else { return }
        if let scope = notification.userInfo?["scope"] as? WorkspacePresenceScope,
           case .workspace(let machine, let workspace, _, _, _) = configuredNode.kind,
           (machine != .cloud(scope.ownerID) || workspace.id != scope.workspaceID) { return }
        configureDisplayHost(node: configuredNode, style: configuredStyle)
        displayHost.invalidateIntrinsicContentSize()
        needsLayout = true
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
        style: CloudTreeStyle = CloudTreeStyleStore.current
    ) {
        configuredNode = node
        configuredStyle = style
        #if DEBUG
        if case .terminal(let row) = node.kind, row.hasUnreadNotification {
            cmuxDebugLog("cloudTree.cell.configure unread terminal=\(row.resource.id.key.suffix(4)) node=\(node.id.suffix(12))")
        }
        #endif
        displayHost.isHidden = false
        configureDisplayHost(node: node, style: style)
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
        } else {
            setAccessibilityLabel(node.searchableTitle)
        }
        updatePresenceSubscription()
    }

    private func configureDisplayHost(node: CloudTreeNode, style: CloudTreeStyle) {
        let presenceHeads: [WorkspacePresenceParticipant] = {
            guard case .workspace(let machine, let workspace, _, _, _) = node.kind else { return [] }
            return collaborators(machine, workspace.id)
        }()
        if case .workspace = node.kind {
            let names = WorkspacePresencePolicy.accessibilityLabel(presenceHeads)
            toolTip = presenceHeads.isEmpty ? nil : names
            setAccessibilityLabel(presenceHeads.isEmpty ? node.searchableTitle : "\(node.searchableTitle), \(names)")
        }
        displayHost.rootView = AnyView(
            CloudTreeRowContentView(kind: node.kind, presenceHeads: presenceHeads, style: style)
                .modifier(CloudSidebarRowDecoration(isPinned: node.isPinned, showsAttentionSlot: node.showsAttentionSlot, hasUnreadNotification: node.hasUnreadAttention, attentionSlot: style.rowGrid.attentionSlot))
                .frame(maxWidth: .infinity, alignment: .leading)
        )
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

    func setHovered(_ hovered: Bool) {
        guard self.hovered != hovered else { return }
        self.hovered = hovered
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        machineReorderAccessibilityActions = nil
        configuredNode = nil
        updatePresenceSubscription()
        toolTip = nil
        hovered = false
    }
}

/// A hosting view that is invisible to hit testing, so the outline row beneath
/// it owns selection, drag, double-click, and the context menu.
final class CloudTreePassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The outline owns all ordinary row interaction. Returning nil here is
        // what keeps a header click from being swallowed by the SwiftUI host.
        return nil
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
