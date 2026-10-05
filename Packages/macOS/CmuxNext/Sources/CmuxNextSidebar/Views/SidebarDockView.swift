import AppKit
import CmuxNextDesign
import Observation

/// The optional bottom destination dock shared by every window surface.
///
/// The dock consumes the same ``SidebarLayoutDocument`` item references as
/// tiles. Its mode is supplied by the window root; the default is hidden.
public final class SidebarDockView: NSView {
    /// The dock presentation selected by the appearance settings.
    public var mode: SidebarDockMode = .off { didSet { applyMode() } }
    /// Called when a destination or pinned workspace is selected.
    public var onActivate: ((LayoutItemRef) -> Void)?

    private let model: SidebarModel
    private let stack = NSStackView()
    private var observation: Task<Void, Never>?
    private var pointerInside = false
    private var symbols: [DockSymbolView] = []

    /// Creates a dock backed by one window's sidebar model.
    /// - Parameter model: The model whose active space and items are shown.
    public init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.space4, bottom: 0, right: Metrics.space4)
        addSubview(stack)
        observation = Task { [weak self, model] in
            for await state in Observations({ (model.layout, model.itemInfo, model.allWorkspaces, model.activeWorkspaceID) }) {
                self?.render(layout: state.0, infos: state.1, workspaces: state.2, active: state.3)
            }
        }
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { observation?.cancel() }

    override public var isFlipped: Bool { true }

    /// Temporarily reveals an overlay dock for keyboard-driven focus.
    public func revealForKey() {
        guard mode == .overlay else { return }
        pointerInside = true
        applyVisibility()
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override public func mouseEntered(with event: NSEvent) { pointerInside = true; applyVisibility() }
    override public func mouseExited(with event: NSEvent) { pointerInside = false; applyVisibility() }

    override public func layout() {
        super.layout()
        stack.frame = bounds
    }

    private func applyMode() {
        layer?.backgroundColor = performWithTheme { mode == .reserved ? Palette.surfaceBackground.withAlphaComponent(0.82).cgColor : nil }
        applyVisibility()
        needsLayout = true
    }

    private func applyVisibility() {
        let visible = mode == .reserved || (mode == .overlay && pointerInside)
        alphaValue = mode == .off ? 0 : (visible ? 1 : 0)
        isMouseTrackingEnabled = mode != .off
    }

    // Kept separate so the overlay remains a hit-testable, transparent strip.
    private var isMouseTrackingEnabled: Bool {
        get { !isHidden }
        set { isHidden = !newValue }
    }

    private func render(layout: SidebarLayoutDocument, infos: [LayoutItemID: SidebarItemInfo],
                        workspaces: [SidebarWorkspace], active: WorkspaceID?) {
        let dockItems = layout.sections(in: .dock, room: model.activeProfileID?.rawValue).flatMap(\.items)
        let destinations = dockItems.isEmpty ? Self.defaultDestinations : dockItems
        let agentItems = workspaces.filter { $0.kind == .harness }
        let pinned = destinations.compactMap { item -> (LayoutItemRef, SidebarItemInfo)? in
            let info = infos[item.id] ?? SidebarItemInfo.fallback(for: item.ref)
            guard !info.isHidden else { return nil }
            return (item.ref, info)
        }
        let workspaceItems = workspaces.filter { workspace in
            destinations.contains { $0.ref == .workspace(workspace.id.rawValue) }
        }
        let entries = pinned + agentItems.map { workspace in
            (LayoutItemRef.workspace(workspace.id.rawValue), SidebarItemInfo(title: workspace.title,
                symbol: workspace.kind.symbol, color: nil, badge: workspace.unread.isUnread ? 1 : nil,
                isActive: workspace.id == active, dockStatus: workspace.activity))
        } + workspaceItems.map { workspace in
            (LayoutItemRef.workspace(workspace.id.rawValue), SidebarItemInfo(title: workspace.title,
                symbol: workspace.kind.symbol, isActive: workspace.id == active, dockStatus: workspace.activity))
        }
        symbols.forEach { $0.removeFromSuperview() }
        symbols = entries.map { ref, info in
            let view = DockSymbolView(info: info)
            view.onPress = { [weak self] in self?.onActivate?(ref) }
            return view
        }
        symbols.forEach(stack.addArrangedSubview)
    }

    private static let defaultDestinations: [LayoutItem] = [
        LayoutItem(id: LayoutItemID("itm_dock_home"), ref: .app("cmux/home"), showsLabel: false),
        LayoutItem(id: LayoutItemID("itm_dock_app_store"), ref: .app("cmux/app-store"), showsLabel: false),
        LayoutItem(id: LayoutItemID("itm_dock_notifications"), ref: .builtIn(.notifications), showsLabel: false),
        LayoutItem(id: LayoutItemID("itm_dock_history"), ref: .builtIn(.history), showsLabel: false),
        LayoutItem(id: LayoutItemID("itm_dock_bookmarks"), ref: .builtIn(.bookmarks), showsLabel: false),
    ]
}

private final class DockSymbolView: NSButton {
    private let dot = CALayer()
    var onPress: (() -> Void)?

    init(info: SidebarItemInfo) {
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.title)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = info.title
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
        wantsLayer = true
        layer?.addSublayer(dot)
        dot.isHidden = info.dockStatus == nil && info.badge == nil
        dot.backgroundColor = Self.color(for: info.dockStatus).cgColor
        setAccessibilityLabel(info.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = min(bounds.height, 22)
        frame.size.width = max(size, 24)
        dot.frame = CGRect(x: bounds.width - 6, y: 1, width: 5, height: 5)
        dot.cornerRadius = 2.5
    }

    @objc private func pressed() { onPress?() }

    private static func color(for state: StatusIndicatorState?) -> NSColor {
        switch state {
        case .waiting: Palette.attention
        case .error: Palette.danger
        case .success: Palette.success
        case .busy, .paused: Palette.textSecondary
        case .idle, nil: Palette.textSecondary
        }
    }
}
