import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Observation

/// The window's icon rail (`window.rail`, at the leading edge by default,
/// like the Codex app's skinny strip): the sidebar's sticky sections (Home,
/// the App Store, History, Notifications, More with the rarely used
/// destinations, the account at the bottom, and anything the user pins
/// there) drawn as one column of icon buttons, while the sidebar keeps only
/// its workspace list. It is a look of the
/// same layout document, so pinning, removing and reordering work as in
/// the sidebar, and each item runs the action the sidebar runs. Tooltips
/// are the item's title plus its live shortcut.
enum WindowRail {
    static let width: CGFloat = 48

    /// The action's title without a menu ellipsis ("Accounts…").
    static func title(for id: ActionID, registry: ActionRegistry) -> String {
        let title = registry.title(for: id) ?? id.rawValue
        return title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// "New Browser Tab (⇧⌘L)", or the title alone while nothing is bound.
    static func toolTip(for id: ActionID, registry: ActionRegistry) -> String {
        let title = title(for: id, registry: registry)
        return registry.shortcutDisplay(for: id).map { WindowStrings.railToolTip(title, shortcut: $0) } ?? title
    }

    /// A built-in item's tooltip (its action's title and shortcut); nil for
    /// other items, which show their own title.
    static func toolTip(for ref: LayoutItemRef, registry: ActionRegistry) -> String? {
        guard let builtIn = ref.builtIn, let action = SidebarBridge.builtInActions[builtIn] else { return nil }
        return toolTip(for: action, registry: registry)
    }
}

/// The rail's column. It uses the terminal theme's strip step beside the
/// sidebar and main pane's rounded frame (`WindowSidebarPanelView`), with a
/// theme-aware hairline at the frame edge. Buttons start below the top row
/// (and the traffic lights), so the rail's top-row space moves the window.
final class WindowRailView: NSView {
    let column: SidebarRailColumnView
    let separator = HairlineView()
    private let registry: ActionRegistry
    private var shortcutObservation: Task<Void, Never>?

    /// Height of the window's top row (the sidebar header): set by the root.
    var topInset: CGFloat = 0 {
        didSet { if oldValue != topInset { needsLayout = true } }
    }

    init(model: SidebarModel, registry: ActionRegistry) {
        self.registry = registry
        column = SidebarRailColumnView(model: model)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        addSubview(column)
        addSubview(separator)
        paint()
        refreshToolTips()
        // Shortcut rebinds change tooltips.
        // task-owner: this view (cancelled in deinit); event-driven (Observation)
        shortcutObservation = Task { [weak self, registry] in
            for await _ in Observations({ SidebarBridge.builtInActions.values.map { registry.shortcutDisplay(for: $0) } }) {
                self?.refreshToolTips()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        shortcutObservation?.cancel()
    }

    override var isFlipped: Bool { true }

    func refreshToolTips() {
        column.toolTipProvider = { [registry] ref in WindowRail.toolTip(for: ref, registry: registry) }
    }

    /// Where the first button starts: below the top row, and below the
    /// traffic lights when they reach lower (the rail is under them at the
    /// window's leading edge, or after a hidden sidebar).
    var buttonsTop: CGFloat {
        var top = topInset
        if let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            top = max(top, convert(lights, from: nil).maxY + Metrics.space2)
        }
        return top.rounded(.up)
    }

    override func layout() {
        super.layout()
        column.frame = bounds
        column.topInset = buttonsTop
        let width = Metrics.lineWidth(Metrics.dividerThickness)
        separator.frame = CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        paint()
    }

    /// Applies the terminal-theme tonal step to the rail surface.
    func paint() {
        performWithTheme { layer?.backgroundColor = Palette.stripStep.cgColor }
        separator.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }
}
