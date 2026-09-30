import CmuxCloud
import AppKit
import CMUXMobileCore
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import SwiftUI

/// Hosts SwiftUI row content inside an `NSOutlineView` cell while leaving every
/// pointer event to the outline: the display host never hit-tests, so click,
/// double-click, drag, and the context menu are handled natively. Rows with
/// actions (machines, groups, section headers) add a second, hit-testable host
/// for their hover buttons, faded in while the outline reports the row hovered.
/// The buttons are always laid out, so hovering never reflows the row, and a
/// faded button keeps its hit area and its place in the accessibility tree.
final class CloudTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CloudTreeCell")
    var machineReorderAccessibilityActions: (() -> [NSAccessibilityCustomAction])?
    private var configuredNode: CloudTreeNode?
    private var configuredStyle = CloudTreeStyleStore.current
    private var observedWorkspace: (machine: SurfaceMachineID, workspaceID: String)?
    private let presenceObserverID = UUID()
    private let collaborators: @MainActor (SurfaceMachineID, String) -> [WorkspacePresenceParticipant]
    private let observeWorkspace: @MainActor (SurfaceMachineID?, String?, UUID) -> Void

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        machineReorderAccessibilityActions?() ?? super.accessibilityCustomActions()
    }

    private let displayHost = CloudTreePassthroughHostingView(rootView: AnyView(EmptyView()))
    private var portsStatus: CloudPortsStatusContent?
    private var portsStatusTrailingConstraint: NSLayoutConstraint?
    private var portAction: @MainActor (CloudPortsStatusAction, SurfaceMachineID) -> Void = { _, _ in }
    private var buttonsHost: CloudTreeRowControlsHostingView?
    private var buttonsTrailingConstraint: NSLayoutConstraint?
    private var buttonsLeadingConstraint: NSLayoutConstraint?
    private var buttonsTopConstraint: NSLayoutConstraint?
    private var buttonsCenterConstraint: NSLayoutConstraint?
    private var hovered = false {
        didSet { buttonsHost?.alphaValue = hovered ? 1 : 0 }
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, collaborators: { machine, workspaceID in
            AppDelegate.shared?.workspacePresenceController.collaborators(forCloudMachine: machine, workspaceID: workspaceID) ?? []
        }, observeWorkspace: { machine, workspaceID, owner in
            AppDelegate.shared?.workspacePresenceController.observeCloudWorkspace(
                machine: machine, workspaceID: workspaceID, owner: owner
            )
        })
    }

    init(
        frame frameRect: NSRect,
        collaborators: @escaping @MainActor (SurfaceMachineID, String) -> [WorkspacePresenceParticipant],
        observeWorkspace: @escaping @MainActor (SurfaceMachineID?, String?, UUID) -> Void = { machine, workspaceID, owner in
            AppDelegate.shared?.workspacePresenceController.observeCloudWorkspace(
                machine: machine, workspaceID: workspaceID, owner: owner
            )
        }
    ) {
        self.collaborators = collaborators
        self.observeWorkspace = observeWorkspace
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
        let next: (machine: SurfaceMachineID, workspaceID: String)? = {
            guard window != nil, superview != nil, !isHiddenOrHasHiddenAncestor,
                  let configuredNode, case .workspace(let machine, let workspace, _, _, _) = configuredNode.kind
            else { return nil }
            return (machine, workspace.id)
        }()
        guard next?.machine != observedWorkspace?.machine || next?.workspaceID != observedWorkspace?.workspaceID else {
            return
        }
        observedWorkspace = next
        observeWorkspace(next?.machine, next?.workspaceID, presenceObserverID)
        // A cell can become visible after it was configured. Refresh once at
        // that boundary; steady-state configure calls must not rehost SwiftUI
        // or re-run the presence roster reconciliation.
        if next != nil, let configuredNode {
            configureDisplayHost(node: configuredNode, style: configuredStyle)
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
        style: CloudTreeStyle = CloudTreeStyleStore.current,
        portAction: @escaping @MainActor (CloudPortsStatusAction, SurfaceMachineID) -> Void = { _, _ in }
    ) {
        configuredNode = node
        configuredStyle = style
        self.portAction = portAction
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
        configureDisplayHost(node: node, style: style)
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
        if CloudTreeRowHoverButtons.hasButtons(for: node.kind) {
            let buttons = buttonsHost ?? makeButtonsHost(style: style)
            buttons.rootView = AnyView(CloudTreeRowHoverButtons(kind: node.kind, machineActions: machineActions, nodeActions: nodeActions))
            buttons.isHidden = false
            buttons.alphaValue = hovered ? 1 : 0
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
        updatePresenceSubscription()
    }

    private func configureDisplayHost(node: CloudTreeNode, style: CloudTreeStyle) {
        let presenceHeads: [WorkspacePresenceParticipant] = {
            guard case .workspace(let machine, let workspace, _, _, _) = node.kind else { return [] }
            return collaborators(machine, workspace.id)
        }()
        // The one place that assigns hover text and the accessibility label.
        // Both used to be written twice, here and again in `configure`, and the
        // second pass reset a workspace row's presence tooltip to nil.
        let description = CloudTreeRowToolTip.describe(node: node, style: style, presenceHeads: presenceHeads)
        toolTip = description.toolTip
        setAccessibilityLabel(description.accessibilityLabel)
        displayHost.rootView = AnyView(
            CloudTreeRowContentView(kind: node.kind, presenceHeads: presenceHeads, style: style, resources: node.resourceSection)
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
        configuredNode = nil
        updatePresenceSubscription()
        toolTip = nil
        hovered = false
        portsStatus?.isHidden = true
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
