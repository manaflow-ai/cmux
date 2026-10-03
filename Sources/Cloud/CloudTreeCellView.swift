import CmuxCloud
import CmuxFoundation
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
    private var configuredNodeActions: CloudTreeNodeActions?
    private var configuredStyle = CloudTreeStyleStore.current
    private var configuredLevel = 0
    /// The level of the machine tab row this row sits under, if any; its
    /// content then starts under the first tab.
    private var configuredPanelLevel: Int?
    /// AppKit's own accessibility-element setting, restored when a reused
    /// spacer cell shows a real row again.
    private var baseIsAccessibilityElement: Bool?
    private let presenceObserverID = UUID()
    private let collaborators: @MainActor (SurfaceMachineID, String) -> [WorkspacePresenceParticipant]

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
    private var showsHoverButtons = false
    /// Machine rows keep their buttons visible without hover, dimmed until
    /// the row is hovered.
    private var buttonsShowAtRest = false
    private var buttonsVisible: Bool { hovered || buttonsShowAtRest }
    private var buttonsAlpha: CGFloat { hovered ? 1 : (buttonsShowAtRest ? Self.restingButtonsAlpha : 0) }
    static let restingButtonsAlpha: CGFloat = 0.55
    /// Whether this row takes the shared hover fill (`CloudTreeRowView`).
    private var showsRowHover = false
    /// The row's fill steps aside while the pointer is on one of its buttons,
    /// so only one highlight shows at a time.
    private var pointerOnButtons = false {
        didSet { updateRowHover() }
    }
    /// Whether the next hover change fades. The outline turns it off when a
    /// reload puts the pointer back on the same row.
    private var hoverAnimates = true
    private var hovered = false {
        didSet {
            if !hovered { pointerOnButtons = false }
            // An invisible overlay still participates in AppKit hit testing.
            // Keep the row's full click target available until the pointer is
            // actually over the row, then reveal the accessory controls.
            buttonsHost?.alphaValue = buttonsAlpha
            buttonsHost?.isHidden = !buttonsVisible || !showsHoverButtons
            updateRowHover()
            if hovered != oldValue, let configuredNode, case .createAction = configuredNode.kind {
                configureDisplayHost(node: configuredNode, style: configuredStyle)
            }
        }
    }

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
        style: CloudTreeStyle = CloudTreeStyleStore.current,
        level: Int = 0,
        panelLevel: Int? = nil,
        portAction: @escaping @MainActor (CloudPortsStatusAction, SurfaceMachineID) -> Void = { _, _ in }
    ) {
        configuredNode = node
        configuredNodeActions = nodeActions
        configuredStyle = style
        configuredLevel = level
        configuredPanelLevel = panelLevel
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
        showsHoverButtons = CloudTreeRowHoverButtons.hasButtons(for: node.kind)
        buttonsShowAtRest = CloudTreeRowHoverButtons.showsAtRest(for: node.kind)
        showsRowHover = Self.showsRowHover(node.kind)
        updateRowHover()
        if showsHoverButtons {
            let buttons = buttonsHost ?? makeButtonsHost(style: style)
            buttons.rootView = AnyView(CloudTreeRowHoverButtons(kind: node.kind, nodeID: node.id, machineActions: machineActions, nodeActions: nodeActions))
            buttons.isHidden = !buttonsVisible || !showsHoverButtons
            buttons.alphaValue = buttonsAlpha
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

    /// New Workspace puts its "+" on the chevron column of the folders under
    /// it; other create rows start on the icon grid like their siblings.
    private static func createRowContentInset(_ action: CloudTreeCreateAction, level: Int, style: CloudTreeStyle) -> CGFloat {
        guard case .newWorkspace = action else { return CloudTreeLayoutMetrics().contentLeading(level: level, style: style) }
        let chevronCenter = CloudTreeNSOutlineView.leadingMargin
            + CGFloat(max(0, level)) * style.indentPerLevel
            + style.rowGrid.disclosureSlot / 2
        return GlobalFontMagnification.scaledSize(chevronCenter - style.iconSlot / 2)
    }

    private func configureDisplayHost(node: CloudTreeNode, style: CloudTreeStyle) {
        // Reused cells can have been hidden from VoiceOver for a spacer row.
        // Restore AppKit's original setting before any early-return content
        // branch, including create-action rows.
        if baseIsAccessibilityElement == nil { baseIsAccessibilityElement = isAccessibilityElement() }
        if case .machineEndSpacer = node.kind {
            setAccessibilityElement(false)
        } else if let baseIsAccessibilityElement {
            setAccessibilityElement(baseIsAccessibilityElement)
        }
        if case .createAction(let action) = node.kind, let nodeActions = configuredNodeActions {
            displayHost.passesThrough = false
            displayHost.rootView = AnyView(
                CloudTreeCreateActionView(
                    action: action, nodeActions: nodeActions, style: style, isHovered: hovered,
                    contentInset: configuredPanelLevel.map { CloudTreeMachineDetailTabsView.panelContentLeading(tabRowLevel: $0, style: style) }
                        ?? Self.createRowContentInset(action, level: configuredLevel, style: style),
                    hoverLeading: configuredPanelLevel.map { CloudTreeMachineDetailTabsView.panelHighlightLeading(tabRowLevel: $0, style: style) }
                        ?? CloudTreeHoverStyle.leading(level: configuredLevel, style: style),
                    animatesHover: hoverAnimates
                )
            )
            toolTip = action.title
            setAccessibilityLabel(action.title)
            return
        }
        if case .machineDetailTabs(let tabs) = node.kind, let nodeActions = configuredNodeActions {
            displayHost.passesThrough = false
            displayHost.rootView = AnyView(
                CloudTreeMachineDetailTabsView(
                    tabs: tabs, style: style,
                    leading: CloudTreeHoverStyle.leading(level: configuredLevel, style: style)
                ) { tab in nodeActions.selectMachineDetailTab(tabs.machine, tab) }
            )
            toolTip = nil
            setAccessibilityLabel(String(localized: "cloudTree.machineDetails.label", defaultValue: "Machine Details"))
            return
        }
        displayHost.passesThrough = true
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
        // A header keeps its icon's clickable spot across reloads: SwiftUI
        // reports the icon's frame only when it moves, and a reload that
        // leaves it in place would otherwise leave the header with no
        // clickable spot, so a click on the icon would toggle the section.
        if CloudTreeRowContentView.sectionRefresh(for: node.kind) == nil { displayHost.interactiveRects = [] }
        displayHost.rootView = AnyView(
            CloudTreeRowContentView(
                kind: node.kind, presenceHeads: presenceHeads, style: style, resources: node.resourceSection,
                onRefresh: Self.sectionRefreshAction(node.kind, configuredNodeActions),
                onInteractiveFrame: { [weak displayHost] frame in displayHost?.interactiveRects = frame.map { [$0] } ?? [] }
            )
                .modifier(CloudSidebarRowDecoration(isPinned: node.isPinned, showsAttentionSlot: node.showsAttentionSlot, hasUnreadNotification: node.hasUnreadAttention, attentionSlot: style.rowGrid.attentionSlot))
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(.named(CloudTreePassthroughHostingView.coordinateSpace))
        )
    }

    /// The refresh a section header's icon runs; nil for every other row.
    private static func sectionRefreshAction(_ kind: CloudTreeNode.Kind, _ actions: CloudTreeNodeActions?) -> (() -> Void)? {
        guard let actions else { return nil }
        switch kind {
        // The panel's one refresh: the fleet and the account's other devices.
        case .cloudMachinesSection, .devicesSection: return { actions.refresh() }
        default: return nil
        }
    }

    /// Rows the pointer can act on take the shared hover fill. Create rows and
    /// tabs draw their own; readings, notes and the closing gap take none.
    static func showsRowHover(_ kind: CloudTreeNode.Kind) -> Bool {
        switch kind {
        case .createAction, .machineDetailTabs, .machineEndSpacer, .resource, .devicesEmpty:
            return false
        case .placeholder(_, let placeholder):
            // A Ports status row is information; only its own button responds.
            return placeholder.portStatus == nil && (placeholder.opensMachine || placeholder.style == .createMachine)
        default:
            return true
        }
    }

    private func updateRowHover() {
        (superview as? CloudTreeRowView)?.setHoverHighlighted(
            hovered && showsRowHover && !pointerOnButtons, animated: hoverAnimates
        )
    }

    /// The node this cell shows, for the outline's hover bookkeeping.
    var nodeID: String? { configuredNode?.id }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePresenceSubscription()
        updateRowHover()
    }

    private func makeButtonsHost(style: CloudTreeStyle) -> CloudTreeRowControlsHostingView {
        let host = CloudTreeRowControlsHostingView(rootView: AnyView(EmptyView()))
        host.onPointerInside = { [weak self] inside in self?.pointerOnButtons = inside }
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

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        guard self.hovered != hovered else { return }
        hoverAnimates = animated
        self.hovered = hovered
        hoverAnimates = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        machineReorderAccessibilityActions = nil
        configuredNode = nil
        configuredNodeActions = nil
        displayHost.passesThrough = true
        updatePresenceSubscription()
        toolTip = nil
        hovered = false
        portsStatus?.isHidden = true
    }
}

/// A hosting view that is invisible to hit testing, so the outline row beneath
/// it owns selection, drag, double-click, and the context menu.
final class CloudTreePassthroughHostingView: NSHostingView<AnyView> {
    /// The coordinate space a row's content reports its clickable spots in.
    static let coordinateSpace = "CloudTreeRowContent"
    var passesThrough = true
    /// Spots that take clicks even while the rest passes through, like a
    /// section header's refresh icon, in this view's (flipped) coordinates.
    var interactiveRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard passesThrough else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if interactiveRects.contains(where: { $0.contains(local) }) { return super.hitTest(point) }
        // The outline owns all ordinary row interaction. Returning nil here is
        // what keeps a header click from being swallowed by the SwiftUI host.
        return nil
    }

    /// Whether a click (or this view's whole content) goes to SwiftUI.
    func acceptsClick(_ event: NSEvent?) -> Bool {
        guard passesThrough else { return true }
        guard let event else { return false }
        let local = convert(event.locationInWindow, from: nil)
        return interactiveRects.contains { $0.contains(local) }
    }
}

/// The hit-testable host for a row's hover buttons. `CloudTreeNSOutlineView`
/// hands mouse-downs inside it to SwiftUI; NSTableView otherwise keeps every
/// click on a non-`NSControl` subview and runs the row's own click action.
final class CloudTreeRowControlsHostingView: NSHostingView<AnyView> {
    /// Reports the pointer entering and leaving the buttons, so the row's
    /// hover fill can step aside for the button's own.
    var onPointerInside: ((Bool) -> Void)?
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    // SwiftUI's own hover areas also report here; only ours speaks for the
    // whole button strip.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === pointerTracking { onPointerInside?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === pointerTracking { onPointerInside?(false) }
    }
}
