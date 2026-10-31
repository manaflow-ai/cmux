#if DEBUG
public import AppKit
public import CmuxNextDesign

/// A capture-only pane sample using the shipped toolbar and menu presentation path.
/// Supplying tools directly enables native rendering only here; no ChromeTunables value is set.
@MainActor
public final class DebugNativeRowToolsFixtureView: NSView {
    private let backdrop = NSVisualEffectView()
    private weak var activeMenu: NSMenu?
    private weak var previousResponder: NSResponder?
    /// The real toolbar used by the synthetic pane.
    public let toolbar = PaneToolbarView(frame: .zero)
    /// Requested row width, capped to the fixture view when laid out.
    public private(set) var rowWidth: CGFloat = 760
    /// DEBUG-only replacement for AppKit's blocking popup in fixture tests. The toolbar's
    /// production HoverReveal hold still wraps this callback.
    public var menuPresentationOverride: (@MainActor (NSMenu, TitlebarBandButton) -> Void)? {
        didSet { toolbar.nativeMenuPresenterOverride = menuPresentationOverride }
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.material = .windowBackground
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        addSubview(toolbar)
        toolbar.nativeMenuPresentationObserver = { [weak self] menu in self?.activeMenu = menu }
        toolbar.moreMenu = { [weak self, weak toolbar] in
            let menu = NSMenu()
            menu.autoenablesItems = false
            toolbar?.nativeOverflowItems().forEach { menu.addItem($0) }
            self?.activeMenu = menu
            return menu
        }
        // Fixture actions are inert: no chat mutation, destructive command, or browser launch.
        toolbar.onNativeTool = { _, _ in }
        toolbar.reveal.setPointerInside(true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    override public func draw(_ dirtyRect: NSRect) {
        // glass-opaque-allow: DEBUG synthetic capture backdrop masks the live page underneath;
        // production controls and the material above it keep their normal glass appearance.
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    /// Replaces the sample tools without changing global settings.
    public func configure(tools: [PaneTabRowTool], width: CGFloat) {
        cancelPendingMenu()
        rowWidth = width
        toolbar.show(more: !tools.isEmpty, lit: false, nativeItems: tools)
        needsLayout = true
        layoutSubtreeIfNeeded()
        toolbar.reveal.setPointerInside(true)
    }

    override public func layout() {
        super.layout()
        backdrop.frame = bounds
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
        cancelPendingMenu()
        perform(#selector(pressMenu(_:)), with: button, afterDelay: 0, inModes: [.default])
        return true
    }

    /// Cancels a scheduled RPC press when the fixture is replaced or dismissed.
    public func cancelPendingMenu() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        activeMenu?.cancelTrackingWithoutAnimation()
        activeMenu = nil
    }

    /// Uses the actual press entry point, including its hover-reveal hold (tests replace presentation).
    @objc public func pressMenu(_ button: TitlebarBandButton) {
        guard button.window != nil, button.superview === toolbar else { return }
        button.performPressMenu()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingMenu()
            if let focused = window?.firstResponder as? NSView, focused.isDescendant(of: self) {
                window?.makeFirstResponder(previousResponder)
            }
            previousResponder = nil
        } else if window == nil {
            previousResponder = newWindow?.firstResponder
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Bounds for a compact gallery crop in top-left window points. When a native menu is open,
    /// its own window is included so callers can prove the composited snapshot contains it.
    /// A menu extending outside the host window is refused because the compositor clips there.
    public func snapshotBounds() -> (capture: NSRect, menuVisible: Bool)? {
        guard let window, window.windowNumber > 0 else { return nil }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let rowInWindow = toolbar.convert(toolbar.bounds, to: nil)
        var capture = topLeftWindowRect(rowInWindow, height: frame.height)
        var menuVisible = false
        let globalTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        for screenRect in nativeMenuScreenRects(window: window) {
            let screenBottomRect = NSRect(x: screenRect.minX, y: globalTop - screenRect.maxY,
                                          width: screenRect.width, height: screenRect.height)
            let menuInWindow = NSRect(x: screenBottomRect.minX - frame.minX,
                                      y: frame.maxY - screenBottomRect.maxY,
                                      width: screenBottomRect.width, height: screenBottomRect.height)
            guard frame.contains(screenBottomRect) else { return nil }
            capture = capture.union(menuInWindow)
            menuVisible = true
        }
        capture = capture.insetBy(dx: -Metrics.space4, dy: -Metrics.space4)
        let bounds = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        capture = capture.intersection(bounds)
        guard !capture.isEmpty else { return nil }
        return (capture.integral, menuVisible)
    }

    private func topLeftWindowRect(_ rect: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func nativeMenuScreenRects(window: NSWindow) -> [NSRect] {
        let parentID = CGWindowID(window.windowNumber)
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
        let hostScreen: NSRect? = window.screen.map { screen in
            let frame = screen.frame
            return NSRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        }
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], parentID) as? [[String: Any]] else { return [] }
        return raw.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID,
                  let number = (info[kCGWindowNumber as String] as? NSNumber).map({ CGWindowID($0.uint32Value) }), number != parentID,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= NSWindow.Level.popUpMenu.rawValue,
                  let value = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  value.width > 1, value.height > 1,
                  hostScreen?.intersects(value) ?? true else { return nil }
            return NSRect(x: value.minX, y: value.minY, width: value.width, height: value.height)
        }
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
