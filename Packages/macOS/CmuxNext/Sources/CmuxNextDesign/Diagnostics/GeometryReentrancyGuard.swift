#if DEBUG
public import AppKit
import CoreFoundation
import ObjectiveC
import os

/// Stops a view geometry callback that re-enters itself on the same view
/// before it overflows the stack (the Crash D class, #24998: a camera
/// `setBoundsSize:` reported a backing change, whose handler set the bounds
/// again, until the main thread's stack ran out).
///
/// Chrome's pattern: a re-entrancy flag held for the scope of the call
/// (`base::AutoReset<bool> resetter(&in_x_, true)` with `DCHECK(!in_x_)`, as in
/// `ui/views/view.cc` `View::Layout` and `ui/compositor/layer.cc`), here a
/// per-thread depth per view and callback, so a callback that legitimately
/// nests a few times passes. The guard wraps NSView's own
/// `viewDidChangeBackingProperties`, `setFrameSize:`, `setBoundsSize:`,
/// `layout` and `resizeSubviewsWithOldSize:`; a subclass override reaches it
/// through `super`, and AppKit's own re-entry (a frame change that resizes
/// subviews, a bounds change that reports a backing change) goes through it.
/// When one view enters one callback more than ``maxDepth`` times on one
/// thread, the call is refused (NSView's implementation does not run, so the
/// recursion ends), a fault is logged with the view class, and the first
/// refusal per view class and callback on the main thread is a ``Report``
/// (``reports``, ``onReentry``).
///
/// Debug builds only, where the stability lab runs (DEV builds); Release
/// and bench builds compile none of it, so the callbacks cost nothing there.
@MainActor
public final class GeometryReentrancyGuard {
    /// The NSView geometry callbacks the guard wraps.
    nonisolated public enum Callback: UInt8, Sendable, CaseIterable {
        case backingProperties
        case frameSize
        case boundsSize
        case layout
        case resizeSubviews

        /// The Objective-C selector of the callback.
        public var selector: Selector {
            switch self {
            case .backingProperties: #selector(NSView.viewDidChangeBackingProperties)
            case .frameSize: #selector(NSView.setFrameSize(_:))
            case .boundsSize: #selector(NSView.setBoundsSize(_:))
            case .layout: #selector(NSView.layout)
            case .resizeSubviews: #selector(NSView.resizeSubviews(withOldSize:))
            }
        }
    }

    /// The first refused call of one view class in one callback.
    nonisolated public struct Report: Sendable, Equatable {
        public var viewClass: String
        public var callback: Callback
        /// The depth the refused call would have had (``maxDepth`` + 1).
        public var depth: Int
        public var at: Date
    }

    /// Nested calls of one callback on one view on one thread that run;
    /// the next one is refused.
    public nonisolated static let maxDepth = 8

    /// A re-entry was refused on the main thread: the first per view class
    /// and callback.
    public var onReentry: ((Report) -> Void)?
    public private(set) var reports: [Report] = []
    /// Refused calls on the main thread since launch, reported or not.
    public private(set) var refusals = 0
    public private(set) var isInstalled = false

    let gate: GeometryReentrancyGate
    private var observer: CFRunLoopObserver?
    private nonisolated static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "geometry-reentrancy")

    public init() {
        let recipient = Recipient()
        gate = GeometryReentrancyGate(limit: Self.maxDepth, refused: Self.refusalHandler(recipient))
        recipient.target = self
    }

    /// The guard the gate reports to, held weakly (the guard owns the gate).
    private final class Recipient: Sendable {
        weak var target: GeometryReentrancyGuard?
    }

    /// Logs the first refusal per view class and callback (any thread); on
    /// the main thread, records each refusal.
    /// Built outside the main actor: the gate calls it on the refusing thread.
    private nonisolated static func refusalHandler(_ recipient: Recipient) -> @Sendable (Report, Bool) -> Void {
        { report, first in
            if first {
                Self.log.fault("geometry re-entry: \(report.viewClass, privacy: .public) \(NSStringFromSelector(report.callback.selector), privacy: .public) entered \(report.depth) times on one thread; refused")
            }
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { recipient.target?.record(report, first: first) } // main-proof: checked above
        }
    }

    /// Wraps the callbacks of NSView. Idempotent.
    public func install() {
        guard !isInstalled else { return }
        isInstalled = true
        for callback in Callback.allCases { Self.swizzle(callback, through: gate) }
        // No geometry callback runs on the main thread while its run loop
        // waits: a depth left then leaked (an exception skipped its exit).
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [gate] _, _ in
            gate.clearCurrentThread()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func record(_ report: Report, first: Bool) {
        refusals += 1
        guard first else { return }
        if reports.count >= 32 { reports.removeFirst() }
        reports.append(report)
        onReentry?(report)
    }

    private typealias PlainIMP = @convention(c) (NSView, Selector) -> Void
    private typealias SizeIMP = @convention(c) (NSView, Selector, NSSize) -> Void

    /// Replaces NSView's implementation of `callback` with one that runs it
    /// through `gate`. Built outside the main actor so the block carries no
    /// isolation check: a view resized off the main thread passes through
    /// its own thread's depths.
    private nonisolated static func swizzle(_ callback: Callback, through gate: GeometryReentrancyGate) {
        let selector = callback.selector
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let imp = method_getImplementation(method)
        let block: Any
        switch callback {
        case .backingProperties, .layout:
            let original = unsafeBitCast(imp, to: PlainIMP.self)
            let plain: @convention(block) (NSView) -> Void = { view in
                gate.run(view, callback) { original(view, selector) }
            }
            block = plain
        case .frameSize, .boundsSize, .resizeSubviews:
            let original = unsafeBitCast(imp, to: SizeIMP.self)
            let sized: @convention(block) (NSView, NSSize) -> Void = { view, size in
                gate.run(view, callback) { original(view, selector, size) }
            }
            block = sized
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

#endif
