#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ObjectiveC

/// RESIZE P0 7 diagnostic (no merge): the seam adapter that swizzles `-[NSView setNeedsLayout:]` once and hands each mark
/// made on the main thread to ``LayoutPassGuard/markDiag``.
final class LayoutMarkHooks {
    private typealias Setter = @convention(c) (NSView, Selector, Bool) -> Void

    static func install() {
        let setter = #selector(setter: NSView.needsLayout)
        guard let method = class_getInstanceMethod(NSView.self, setter) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        method_setImplementation(method, imp_implementationWithBlock(setterBlock(original, setter)))
    }

    private nonisolated static func setterBlock(_ original: Setter, _ selector: Selector) -> @convention(block) (NSView, Bool) -> Void {
        { view, flag in
            if flag, Thread.isMainThread, !view.needsLayout {
                MainActor.assumeIsolated { LayoutPassGuard.shared.markDiag?.marked(view) } // main-proof: checked on the line above
            }
            original(view, selector, flag)
        }
    }
}
#endif
