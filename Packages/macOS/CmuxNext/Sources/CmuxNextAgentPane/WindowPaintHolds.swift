public import AppKit

/// A window that lists its paint holds (``PanePaintHold``), so the person's input there ends them before it is
/// delivered.
@MainActor
public protocol PaintHoldWindow: AnyObject {
    /// The window's holds on screen now.
    var paintHolds: WindowPaintHolds { get }
}

/// One window's paint holds on screen (audit B1/B2): a key, click or scroll in the window ends every one of them
/// before the window delivers it, so the input lands on the content the person switched to, never on a view kept
/// invisible behind the content they left.
@MainActor
public final class WindowPaintHolds {
    private let live = NSHashTable<PanePaintHold>.weakObjects()

    public init() {}

    /// Whether the person's input of `type` ends the window's holds.
    public static func ends(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: true
        default: false
        }
    }

    /// Ends every hold on screen in the window, before the event of `type` is delivered (no work for other input).
    // perf-hot: 100ns main-turn (every event the window sends: a type test and a count read when nothing holds)
    public func willSend(_ type: NSEvent.EventType) {
        guard live.count > 0, Self.ends(type) else { return }
        endAll()
    }

    /// Ends every hold on screen in the window.
    public func endAll() {
        for hold in live.allObjects { hold.endForInput() }
    }

    func add(_ hold: PanePaintHold) { live.add(hold) }
    func remove(_ hold: PanePaintHold) { live.remove(hold) }
}
