#if DEBUG
public import AppKit
public import CmuxNextDesign

/// A capture-only pane sample using the shipped toolbar and menu presentation path.
/// Supplying tools directly enables native rendering only here; no ChromeTunables value is set.
@MainActor
public final class DebugNativeRowToolsFixtureView: NSView {
    /// The real toolbar used by the synthetic pane.
    public let toolbar = PaneToolbarView(frame: .zero)
    /// Requested row width, capped to the fixture view when laid out.
    public private(set) var rowWidth: CGFloat = 760

    override public init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(toolbar)
        toolbar.moreMenu = { [weak toolbar] in
            let menu = NSMenu()
            menu.autoenablesItems = false
            toolbar?.nativeOverflowItems().forEach { menu.addItem($0) }
            return menu
        }
        // Fixture actions are inert: no chat mutation, destructive command, or browser launch.
        toolbar.onNativeTool = { _, _ in }
        toolbar.reveal.setPointerInside(true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    /// Replaces the sample tools without changing global settings.
    public func configure(tools: [PaneTabRowTool], width: CGFloat) {
        rowWidth = width
        toolbar.show(more: !tools.isEmpty, lit: false, nativeItems: tools)
        needsLayout = true
        layoutSubtreeIfNeeded()
        toolbar.reveal.setPointerInside(true)
    }

    override public func layout() {
        super.layout()
        let width = min(rowWidth, max(0, bounds.width - Metrics.space4 * 2))
        toolbar.frame = NSRect(x: max(Metrics.space4, bounds.width - Metrics.space4 - width),
                               y: Metrics.space4, width: width,
                               height: PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2))
        toolbar.layoutSubtreeIfNeeded()
    }

    /// Schedules a normal press after the RPC returns. The main run loop stays available to
    /// snapshot/dismiss RPCs while NSMenu tracks, just as in DebugObjectMenu's delayed popup.
    public func openMenu(_ id: String) -> Bool {
        guard let button = menuButton(id) else { return false }
        perform(#selector(pressMenu(_:)), with: button, afterDelay: 0, inModes: [.default])
        return true
    }

    /// Uses the actual press entry point, including its hover-reveal hold (tests replace presentation).
    @objc public func pressMenu(_ button: TitlebarBandButton) {
        guard button.window != nil, button.superview === toolbar else { return }
        button.performPressMenu()
    }

    /// Finds a visible enabled menu button by its page-supplied id.
    public func menuButton(_ id: String) -> TitlebarBandButton? {
        toolbar.layoutSubtreeIfNeeded()
        guard let index = toolbar.nativeItems.firstIndex(where: { $0.id == id }),
              toolbar.nativeButtons.indices.contains(index) else { return nil }
        let button = toolbar.nativeButtons[index]
        return button.isEnabled && !button.isHidden && button.pressMenu != nil ? button : nil
    }
}
#endif
