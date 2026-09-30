import AppKit
import CmuxNextDesign
import CmuxNextResources
import CmuxNextWakeups

/// The workspace hover card: title, cwd, and the workspace's CPU and memory
/// summed over its tabs (each process once), its heaviest tabs, and the
/// shared processes on their own line. It replaces the row tooltip.
///
/// Resources are sampled from hover start (the CPU baseline) until the
/// card hides; nothing is sampled while no card is pending or shown.
final class WorkspaceHoverCardController {
    let resources = ResourceCardSampler(source: nil)
    /// Ends a card an action opened (not the pointer).
    private let pin = PinnedCardDismissal()
    /// Hover time before the first card; later cards show at once while one
    /// is visible (moving down the list).
    var delay: Duration = .milliseconds(600)
    private let showTimer: DemandTimer
    private var panel: WorkspaceHoverCardPanel?
    private(set) var shownID: WorkspaceID?
    private var pendingID: WorkspaceID?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        showTimer = DemandTimer(owner: "Sidebar.hoverCard", clock: clock)
    }

    var isVisible: Bool { shownID != nil }

    /// The pointer is over `workspace`'s row, whose frame on screen is `anchor`.
    func hover(_ workspace: SidebarWorkspace, anchor: CGRect, parent: NSWindow?) {
        guard shownID != workspace.id, pendingID != workspace.id else { return }
        pin.disarm()
        startResources(for: workspace)
        if isVisible {
            show(workspace, anchor: anchor, parent: parent)
            return
        }
        pendingID = workspace.id
        showTimer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, self.pendingID == workspace.id else { return }
            self.show(workspace, anchor: anchor, parent: parent)
        }
    }

    /// Shows the card now, without the hover delay, until the next key
    /// press, click or scroll (the "Show Resource Usage" actions).
    func showPinned(_ workspace: SidebarWorkspace, anchor: CGRect, parent: NSWindow?) {
        showTimer.cancel()
        pendingID = nil
        startResources(for: workspace)
        show(workspace, anchor: anchor, parent: parent)
        guard shownID == workspace.id else {
            resources.close()
            return
        }
        pin.arm { [weak self] in self?.hide() }
    }

    private func startResources(for workspace: SidebarWorkspace) {
        resources.open(.workspace(workspace.id.rawValue)) { [weak self] report in
            guard let self, self.shownID == workspace.id else { return }
            self.panel?.setResources(report)
        }
    }

    /// The hovered workspace's row content changed.
    func refresh(_ workspace: SidebarWorkspace) {
        guard shownID == workspace.id else { return }
        panel?.configure(workspace)
    }

    func hide() {
        showTimer.cancel()
        pendingID = nil
        pin.disarm()
        resources.close()
        guard shownID != nil else { return }
        shownID = nil
        panel?.dismiss()
    }

    private func show(_ workspace: SidebarWorkspace, anchor: CGRect, parent: NSWindow?) {
        guard let parent, parent.isVisible else { return }
        pendingID = nil
        let panel = panel ?? WorkspaceHoverCardPanel()
        self.panel = panel
        let sliding = isVisible
        shownID = workspace.id
        panel.configure(workspace)
        panel.setResources(resources.report)
        panel.present(beside: anchor, parent: parent, sliding: sliding)
    }

    /// Design tokens changed: rebuild the card at the new sizes next time.
    func tokensChanged() {
        hide()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }
}

/// Borderless, non-activating child window hosting the glass card.
final class WorkspaceHoverCardPanel: NSPanel {
    private static var padding: CGFloat { Metrics.space5 }
    static var cardWidth: CGFloat { 280 }

    private let glass: NSGlassEffectView
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    let resources = ResourceSummaryView()
    private weak var parentWindowRef: NSWindow?
    private var anchor: CGRect = .zero

    init() {
        let content = NSView()
        glass = Glass.makePanel(content: content, cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ThemeStore.shared.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // A no-activate test run is never active; its cards must still show.
        hidesOnDeactivate = !WindowPlacement.noActivate
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = glass

        titleLabel.font = Typography.bodyEmphasized
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = Typography.caption
        subtitleLabel.textColor = Palette.textSecondary
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        resources.style = .workspace(topConsumers: 3)

        let stack = NSStackView(views: [titleLabel, subtitleLabel, resources])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.setCustomSpacing(Metrics.space3, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resources.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(_ workspace: SidebarWorkspace) {
        titleLabel.stringValue = workspace.title
        subtitleLabel.stringValue = workspace.subtitle ?? ""
        subtitleLabel.isHidden = (workspace.subtitle ?? "").isEmpty
    }

    func setResources(_ report: ResourceReport?) {
        resources.show(report)
        // The heaviest-tabs rows can appear with the first sample.
        if isVisible { place(sliding: false) }
    }

    /// Shows the card to the right of the row, top-aligned with it.
    func present(beside anchor: CGRect, parent: NSWindow, sliding: Bool) {
        if parentWindowRef !== parent {
            parentWindowRef?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
            parentWindowRef = parent
        }
        self.anchor = anchor
        place(sliding: sliding)
        if !isVisible || alphaValue < 1 {
            if !isVisible { alphaValue = 0 }
            orderFront(nil)
            Motion.animateTimed(.fadeIn) { animator().alphaValue = 1 }
        }
    }

    private func place(sliding: Bool) {
        glass.layoutSubtreeIfNeeded()
        let size = glass.fittingSize
        var origin = CGPoint(x: anchor.maxX + Metrics.space2, y: anchor.maxY - size.height)
        if let screen = parentWindowRef?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let margin = Metrics.space2
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        let frame = CGRect(origin: origin, size: size)
        if sliding, isVisible, Motion.animatesMovement {
            Motion.animateTimed(.panel) { animator().setFrame(frame, display: true) }
        } else {
            setFrame(frame, display: true)
        }
    }

    func dismiss() {
        Motion.animateTimed(.fadeOut, { animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.parentWindowRef?.removeChildWindow(self)
            self.parentWindowRef = nil
            self.orderOut(nil)
        })
    }
}
