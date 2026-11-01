public import AppKit
import CmuxNextCompat
import ObjectiveC

/// What a capture backdrop (``CaptureBackdropPanel``) shows behind a window, so its translucency
/// and the blur of its glass are visible in a capture: a uniform dark desktop shows neither.
public nonisolated enum CaptureBackdropPattern: Equatable, Sendable {
    /// Light and dark squares, ``cell`` points on a side.
    case checker
    /// Vertical bands of two saturated colors, ``cell`` points wide.
    case stripes
    /// An image file, scaled to fill the backdrop.
    case image(URL)

    /// The side of a checker square and the width of a stripe, in points.
    public static let cell: CGFloat = 32

    /// The pattern a `debug.capture_backdrop` `pattern` names (`checker`, `stripes`, or
    /// `image:PATH`, an absolute path), else nil.
    public init?(name: String) {
        switch name {
        case "checker": self = .checker
        case "stripes": self = .stripes
        default:
            guard name.hasPrefix("image:") else { return nil }
            let path = String(name.dropFirst("image:".count))
            guard path.hasPrefix("/") else { return nil }
            self = .image(URL(fileURLWithPath: path))
        }
    }

    /// The bytes of an `.image` pattern's file, read off the main thread; nil for the other
    /// patterns or a file that cannot be read.
    @concurrent
    public nonisolated func imageData() async -> Data? {
        guard case .image(let url) = self else { return nil }
        return try? Data(blockingContentsOf: url)
    }

    /// The pattern's two colors.
    var colors: (NSColor, NSColor) {
        switch self {
        case .checker: (NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1))
        case .stripes, .image: (NSColor(srgbRed: 1.0, green: 0.35, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.18, green: 0.5, blue: 0.98, alpha: 1))
        }
    }

    /// Whether the cell at `point` (in the backdrop's points) takes the first color.
    func isFirstColor(at point: CGPoint) -> Bool {
        let column = Int((point.x / Self.cell).rounded(.down))
        let row = Int((point.y / Self.cell).rounded(.down))
        switch self {
        case .checker: return (column + row).isMultiple(of: 2)
        case .stripes, .image: return column.isMultiple(of: 2)
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// A capture backdrop: a borderless window of the app that only draws a ``CaptureBackdropPattern``,
/// ordered just behind its ``target`` window, which a snapshot of the target
/// (``NSWindow/compositedSnapshotWithOverlays()``) composites behind it. A capture slot shares its
/// mini's desktop with other slots, and the window server composites only the windows a snapshot
/// names, so a translucent window or its glass shows nothing behind it in a snapshot; with the
/// backdrop behind it the window's translucency and the blur of its glass show as on screen. It
/// belongs to the app process and goes with it: it is never the desktop picture. It never takes a
/// click, a key, the key or main role, or a place in the Window menu. It is closed when it is
/// replaced or taken away and when its target closes (``remove()``), so no window-server window
/// outlives it.
public final class CaptureBackdropPanel: NSPanel {
    public let pattern: CaptureBackdropPattern
    /// The window it is behind, which keeps it (``NSWindow/captureBackdrop``).
    public private(set) weak var target: NSWindow?
    /// The key under which its target window keeps it.
    static let retainKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    /// Its target's close, which removes it. Stops when it is removed (``remove()``) or released;
    /// it holds the panel weakly, so the target keeping the panel makes no cycle.
    private var targetClose: MainActorObservation?
    /// Whether ``remove()`` has run, so a second call does nothing.
    private(set) var isRemoved = false

    init(pattern: CaptureBackdropPattern, image: NSImage?, frame: NSRect, target: NSWindow) {
        self.pattern = pattern
        self.target = target
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        targetClose = MainActorObservation(NSWindow.willCloseNotification, object: target) { [weak self] in
            self?.remove()
        }
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        hasShadow = false
        isOpaque = true
        animationBehavior = .none
        identifier = NSUserInterfaceItemIdentifier("cmux.captureBackdrop")
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        contentView = CaptureBackdropView(pattern: pattern, image: image)
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    /// Takes it away for good: stops watching its target, closes it (so the window server drops
    /// its window), and has its target let go of it. Once only.
    func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        targetClose = nil
        // close() also takes it off screen.
        close()
        if let target, objc_getAssociatedObject(target, Self.retainKey) as? CaptureBackdropPanel === self {
            objc_setAssociatedObject(target, Self.retainKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

#endif

extension NSWindow {
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The capture backdrop shown behind this window (``CaptureBackdropPanel``), if any. The window
    /// keeps it, so it goes with the window.
    public var captureBackdrop: CaptureBackdropPanel? {
        (objc_getAssociatedObject(self, CaptureBackdropPanel.retainKey) as? CaptureBackdropPanel).flatMap { $0.isVisible ? $0 : nil }
    }

    /// Shows `pattern` just behind this window, covering its screen (so a move on that screen
    /// keeps it covered; set it again after the window changes screens), and takes away (closes)
    /// the backdrop it had and any whose window is gone; nil only takes them away. Closing this
    /// window takes its backdrop away too. `image` is an `.image` pattern's image
    /// (``CaptureBackdropPattern/imageData()``).
    @discardableResult
    public func setCaptureBackdrop(_ pattern: CaptureBackdropPattern?, image: NSImage? = nil) -> CaptureBackdropPanel? {
        (objc_getAssociatedObject(self, CaptureBackdropPanel.retainKey) as? CaptureBackdropPanel)?.remove()
        objc_setAssociatedObject(self, CaptureBackdropPanel.retainKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        for panel in NSApp.windows.compactMap({ $0 as? CaptureBackdropPanel }) where panel.target == nil {
            panel.remove()
        }
        guard let pattern else { return nil }
        let panel = CaptureBackdropPanel(pattern: pattern, image: image, frame: (screen?.frame ?? frame).union(frame), target: self)
        objc_setAssociatedObject(self, CaptureBackdropPanel.retainKey, panel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        panel.order(.below, relativeTo: windowNumber)
        return panel
    }

    /// The window numbers of every capture backdrop the app shows, which a snapshot never takes
    /// as an overlay over its window (``floatingWindowsSnapshot()``).
    static var captureBackdropNumbers: Set<Int> {
        Set(NSApp.windows.compactMap { ($0 as? CaptureBackdropPanel).flatMap { $0.windowNumber > 0 ? $0.windowNumber : nil } })
    }

    /// The window number a snapshot of this window composites behind it: its capture backdrop's,
    /// while that is on screen; else nil.
    var captureBackdropNumber: Int? {
        guard let backdrop = captureBackdrop, backdrop.windowNumber > 0 else { return nil }
        return backdrop.windowNumber
    }

    #else
    /// A Release build has no capture backdrop (``debug.capture_backdrop`` is DEBUG and bench only): none to skip.
    static var captureBackdropNumbers: Set<Int> { [] }

    /// A Release build has no capture backdrop: nothing composites behind a window.
    var captureBackdropNumber: Int? { nil }
    #endif

    /// The windows a snapshot composites, topmost first: `front` (the window and what is over it,
    /// already topmost first), then the backdrop, always last, so it is behind everything else
    /// whatever the window server's on-screen order is.
    nonisolated static func compositeOrder(front: [Int], backdrop: Int?) -> [Int] {
        guard let backdrop else { return front }
        return front.filter { $0 != backdrop } + [backdrop]
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// Draws a ``CaptureBackdropPattern``, or its image.
final class CaptureBackdropView: NSView {
    private let pattern: CaptureBackdropPattern
    private let image: NSImage?

    init(pattern: CaptureBackdropPattern, image: NSImage?) {
        self.pattern = pattern
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            return
        }
        let (first, second) = pattern.colors
        second.setFill()
        dirtyRect.fill()
        first.setFill()
        let cell = CaptureBackdropPattern.cell
        var y = (dirtyRect.minY / cell).rounded(.down) * cell
        while y < dirtyRect.maxY {
            var x = (dirtyRect.minX / cell).rounded(.down) * cell
            while x < dirtyRect.maxX {
                let square = NSRect(x: x, y: y, width: cell, height: cell)
                if pattern.isFirstColor(at: CGPoint(x: square.midX, y: square.midY)) { square.fill() }
                x += cell
            }
            y += cell
        }
    }
}
#endif
