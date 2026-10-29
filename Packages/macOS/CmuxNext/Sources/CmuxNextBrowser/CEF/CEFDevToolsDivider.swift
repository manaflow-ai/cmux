import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups

/// The line between a CEF page and its docked DevTools. Drag it to resize
/// (the page and DevTools windows punch a hole for its grab area, so the
/// mouse reaches it over both); its menu moves DevTools like the dock
/// side items of the DevTools menu.
final class CEFDevToolsDivider: NSView {
    weak var devTools: CEFDevToolsController?
    private var dragging = false
    /// A drag moves the line to this point (its superview's coordinates): the controller's
    /// `dragDivider(to:)`.
    var onMove: ((CGPoint) -> Void)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`, ``CEFRuntime/pointerFrames``):
    /// the line moves on a frame interval's first drag event and once more at its frame, to the latest
    /// point, as Chromium delivers rAF-aligned moves (main_thread_event_queue.cc). Nil: every drag
    /// event moves it.
    var pointerFrames: FrameInputCoalescers?
    /// This drag's consumer of its window's coalescer, from mouse-down to mouse-up.
    private var frameDrag: PointerFrameConsumer?

    nonisolated override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The page and DevTools are their own windows and take key when used,
    /// so the drag's first click often lands while cmux's window is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let devTools else { return }
        performWithTheme { Borders.color(Palette.separator) }.setFill()
        let line = devTools.layout.dock.isSide
            ? NSRect(x: bounds.midX - CEFDevToolsLayout.lineThickness / 2, y: 0, width: CEFDevToolsLayout.lineThickness, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - CEFDevToolsLayout.lineThickness / 2, width: bounds.width, height: CEFDevToolsLayout.lineThickness)
        line.fill()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addCursorUpdateArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The resize cursor across the dock's side (set when the pointer enters, no cursor rects).
    var resizeCursor: NSCursor { devTools?.layout.dock.isSide == true ? .resizeLeftRight : .resizeUpDown }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        endFrameDrag()
        frameDrag = window.flatMap { pointerFrames?.coalescer(for: $0) }?.consumer(owner: "CEFDevToolsDivider") { [weak self] input in
            self?.drag(to: NSPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
    }

    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every drag event)
        guard dragging else { return }
        if let frameDrag {
            frameDrag.post(event)
        } else {
            drag(to: event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        // The frame's pending move lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        endFrameDrag()
        dragging = false
        devTools?.rememberLayout()
    }

    /// Leaving the window mid-drag: no mouse-up comes, so nothing it has pending may land later.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        endFrameDrag()
        dragging = false
    }

    /// The line goes to `windowPoint` (window coordinates).
    private func drag(to windowPoint: NSPoint) { // perf-hot: 2ms resize-drag (each move the line takes)
        guard dragging, let container = superview else { return }
        onMove?(container.convert(windowPoint, from: nil))
    }

    /// Drops this drag's consumer and anything it still has pending.
    private func endFrameDrag() {
        frameDrag?.cancel()
        frameDrag = nil
    }

    /// The dock side choices (CEF runs DevTools with docking off, so its
    /// own three-dot menu has none).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab = devTools?.tab else { return nil }
        let menu = NSMenu()
        for (title, dock) in [(Strings.devToolsDockLeft, BrowserDevToolsDock.left), (Strings.devToolsDockBottom, .bottom),
                              (Strings.devToolsDockRight, .right), (Strings.devToolsUndock, .window)] {
            let item = NSMenuItem(title: title, action: #selector(dockItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dock.rawValue
            item.state = tab.devTools.dock == dock ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: Strings.devToolsClose, action: #selector(closeItem(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func dockItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let dock = BrowserDevToolsDock(rawValue: raw) else { return }
        devTools?.perform(.dock(dock))
    }

    @objc private func closeItem(_ sender: NSMenuItem) {
        devTools?.perform(.close)
    }
}
