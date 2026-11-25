public import AppKit

/// A window's extension status items in its top row, after the toolbar band (``AppStatusItems``,
/// place `titlebar`): one view per item, each a view of the item's one mount, sized to its scene's
/// natural width. Hidden while no item shows or none has drawn yet, so it takes no room unless an
/// installed extension contributes one.
@MainActor
public final class AppStatusStripView: NSView {
    public static let identifier = NSUserInterfaceItemIdentifier("cmux.titlebar.extensionStatus")
    /// The widest one item may be.
    static let maxItemWidth: CGFloat = 220
    /// The gap between items.
    static let spacing: CGFloat = 6

    /// Runs when the strip's width changes or it shows or hides: the top row lays out again.
    public var onWidthChange: (() -> Void)?
    private let items: AppStatusItems
    private var views: [(app: String, mount: String, view: AppSceneHostingView)] = []
    private var lastWidth: CGFloat = 0

    public init(items: AppStatusItems, onWidthChange: (() -> Void)? = nil) {
        self.items = items
        self.onWidthChange = onWidthChange
        super.init(frame: .zero)
        identifier = Self.identifier
        isHidden = true
        items.observe(owner: self) { [weak self] in self?.rebuild() }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated public override var isFlipped: Bool { true }

    /// The strip's width now: its drawn items and the gaps between them.
    public var width: CGFloat {
        let widths = views.compactMap { itemWidth($0.view) }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + Self.spacing * CGFloat(widths.count - 1)
    }

    private func itemWidth(_ view: AppSceneHostingView) -> CGFloat? {
        guard let width = view.preferredWidth, width > 0 else { return nil }
        return min(width, Self.maxItemWidth)
    }

    private func rebuild() {
        let entries = items.entries(at: .titlebar)
        let wanted = entries.map(\.mount.id)
        guard wanted != views.map({ $0.mount }) else {
            sizeChanged()
            return
        }
        var old: [String: AppSceneHostingView] = [:]
        for entry in views { old[entry.mount] = entry.view }
        views = entries.map { entry in
            let view = old.removeValue(forKey: entry.mount.id) ?? makeView(entry)
            return (entry.item.app, entry.mount.id, view)
        }
        for view in old.values { view.removeFromSuperview() }
        sizeChanged()
    }

    private func makeView(_ entry: AppStatusItems.Entry) -> AppSceneHostingView {
        let view = entry.mount.makeView()
        view.setAccessibilityLabel(entry.item.title)
        view.onContentSizeChange = { [weak self] in self?.sizeChanged() }
        addSubview(view)
        return view
    }

    private func sizeChanged() {
        let width = width
        let hidden = width == 0
        needsLayout = true
        guard width != lastWidth || hidden != isHidden else { return }
        lastWidth = width
        isHidden = hidden
        onWidthChange?()
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        for entry in views {
            guard let width = itemWidth(entry.view) else {
                entry.view.isHidden = true
                continue
            }
            entry.view.isHidden = false
            let height = min(entry.view.preferredHeight(width: width), bounds.height)
            entry.view.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
            x += width + Self.spacing
        }
    }
}
