import AppKit
import CoreFoundation
import ObjectiveC

/// The callback seam of ``LayoutPassGuard``: the blocks that replace `-[NSView layout]` and
/// `-[NSWindow layoutIfNeeded]`, and the main run loop's before-waiting observer.
///
/// AppKit and Core Foundation call these with no Swift isolation. Each callback checks that it
/// is on the main thread and enters the main actor once to call the guard it was given; a view
/// or a window laid out on another thread passes through uncounted. The guard itself holds no
/// callback code, and the hooks read no global guard.
struct LayoutPassHooks {
    /// The guard the callbacks count into.
    let guardian: LayoutPassGuard

    /// Replaces both methods and adds the observer to the main run loop in its common modes.
    /// The replacements are process-wide: call this once per process.
    ///
    /// - Returns: The observer, which the guard keeps for the life of the process.
    func install() -> CFRunLoopObserver? {
        let guardian = guardian
        Self.swizzleLayout(guardian)
        Self.swizzleWindowLayout(guardian)
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            // main-proof: added to the main run loop only (CFRunLoopAddObserver below), which runs its observers on the main thread
            MainActor.assumeIsolated { guardian.dropLeakedWindowLayouts() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        return observer
    }

    private typealias LayoutIMP = @convention(c) (NSView, Selector) -> Void
    private typealias WindowLayoutIMP = @convention(c) (NSWindow, Selector) -> Void

    private static func swizzleLayout(_ guardian: LayoutPassGuard) {
        let selector = #selector(NSView.layout)
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: LayoutIMP.self)
        method_setImplementation(method, imp_implementationWithBlock(layoutOverride(calling: original, selector, counting: guardian)))
    }

    private static func swizzleWindowLayout(_ guardian: LayoutPassGuard) {
        let selector = #selector(NSWindow.layoutIfNeeded)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: WindowLayoutIMP.self)
        method_setImplementation(method, imp_implementationWithBlock(windowLayoutOverride(calling: original, selector, counting: guardian)))
    }

    /// Built outside the main actor so the block carries no isolation check: AppKit lays out on the
    /// main thread, and a view laid out elsewhere is passed through uncounted.
    private nonisolated static func layoutOverride(calling original: LayoutIMP, _ selector: Selector,
                                                   counting guardian: LayoutPassGuard) -> @convention(block) (NSView) -> Void {
        { view in
            original(view, selector)
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { guardian.record(view) } // main-proof: checked above
        }
    }

    /// Brackets one `layoutIfNeeded` of a window (AppKit's unit for its pass limit); off the main
    /// thread it passes through.
    private nonisolated static func windowLayoutOverride(calling original: WindowLayoutIMP, _ selector: Selector,
                                                         counting guardian: LayoutPassGuard) -> @convention(block) (NSWindow) -> Void {
        { window in
            guard Thread.isMainThread else { return original(window, selector) }
            MainActor.assumeIsolated { // main-proof: checked above
                guardian.windowLayoutWillBegin(window)
                original(window, selector)
                guardian.windowLayoutDidEnd(window)
            }
        }
    }
}
