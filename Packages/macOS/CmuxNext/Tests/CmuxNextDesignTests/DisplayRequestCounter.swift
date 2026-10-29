import AppKit
import ObjectiveC

/// Counts the repaint requests a view makes on itself: `needsDisplay = true` and `setNeedsDisplay(_:)`.
///
/// The invalidation tests check that an equal value requests no repaint. They read `needsDisplay` back
/// before; in the fleet's test host that read does not follow the requests (fleet probe 5554ae33: outside a
/// window a set `true` reads back false, and a window's label cannot be cleared to false), so the tests failed
/// both ways while the product asked for exactly what it should. The requests themselves are the contract,
/// so these tests count them. AppKit's own requests count too, as they would in the app.
///
/// The hook replaces NSView's two IMPs once for the test process and stays; it counts only the views a
/// test watches, so suites running beside it see AppKit's behavior unchanged.
@MainActor
final class DisplayRequestCounter {
    private var counts: [ObjectIdentifier: Int] = [:]
    private var watched: [ObjectIdentifier: Weak] = [:]

    private struct Weak { weak var view: NSView? }

    init() { Self.install() }

    /// Starts counting `view`'s requests from zero.
    func watch(_ view: NSView) {
        let id = ObjectIdentifier(view)
        watched[id] = Weak(view: view)
        counts[id] = 0
        if !Self.counters.contains(where: { $0.counter === self }) { Self.counters.append(WeakCounter(counter: self)) }
    }

    /// The requests `view` made since ``watch(_:)`` or the last ``reset(_:)``. One `needsDisplay = true` may
    /// count more than once (AppKit can forward it to `setNeedsDisplay(_:)`): compare with zero, not a number.
    func requests(_ view: NSView) -> Int { counts[ObjectIdentifier(view)] ?? 0 }

    func reset(_ view: NSView) { counts[ObjectIdentifier(view)] = 0 }

    fileprivate func note(_ view: NSView) {
        let id = ObjectIdentifier(view)
        guard watched[id]?.view === view else { return }
        counts[id, default: 0] += 1
    }

    // MARK: The hook

    private struct WeakCounter { weak var counter: DisplayRequestCounter? }
    private static var counters: [WeakCounter] = []
    private static var installed = false

    private typealias FlagIMP = @convention(c) (NSView, Selector, ObjCBool) -> Void
    private typealias RectIMP = @convention(c) (NSView, Selector, NSRect) -> Void

    fileprivate static func record(_ view: NSView) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            counters.removeAll { $0.counter == nil }
            for entry in counters { entry.counter?.note(view) }
        }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let flag = #selector(setter: NSView.needsDisplay)
        // SAFETY (both hooks): each IMP is NSView's own implementation of the selector it is cast for, read once
        // here and called with that selector's arguments; the blocks replace it for the test process and stay.
        if let method = unsafe class_getInstanceMethod(NSView.self, flag) {
            let original = unsafe unsafeBitCast(method_getImplementation(method), to: FlagIMP.self)
            let block: @convention(block) (NSView, ObjCBool) -> Void = { view, value in
                if value.boolValue { DisplayRequestCounter.record(view) }
                original(view, flag, value)
            }
            unsafe method_setImplementation(method, imp_implementationWithBlock(block))
        }
        let rect = #selector(NSView.setNeedsDisplay(_:))
        if let method = unsafe class_getInstanceMethod(NSView.self, rect) {
            let original = unsafe unsafeBitCast(method_getImplementation(method), to: RectIMP.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { view, dirty in
                DisplayRequestCounter.record(view)
                original(view, rect, dirty)
            }
            unsafe method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
