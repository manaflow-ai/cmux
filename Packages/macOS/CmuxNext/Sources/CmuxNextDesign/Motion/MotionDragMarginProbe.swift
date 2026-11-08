#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ObjectiveC
import QuartzCore

/// ZOOM VARIANTS 4 drag-margin probe (fork only, never merged): what schedules the window's structural-region rebuild
/// (AppKit `-[NSWindow _updateStructuralRegionsOnNextDisplayCycle]`, which runs `_resetDragMargins` in the display
/// cycle) in a Z4 key turn. While `debug.motion` records, each reset is one span
/// `zk.drm.s<schedules>.i<cursor-rect invalidations>.<callers>`, its ms the reset's own time; callers are the first app
/// frames (mangled) of the first schedules since the last reset, and `zk.icr.<view class>` names each invalidation
/// AppKit's `invalidateCursorRects(for:)` receives. Installed at the first `MotionTrace.start()`.
///
/// What the probe counts between two drag-margin resets (held by its swizzled blocks, no static storage).
@MainActor
final class MotionDragMarginProbe {
    var schedules = 0
    var invalidations = 0
    var callers: [String] = []

    /// Installs the probe once per process: a marker method on NSWindow says it is in.
    static func install() {
        let marker = NSSelectorFromString("cmuxZoomVariants4DragMarginProbe")
        let noop: @convention(block) (AnyObject) -> Void = { _ in }
        guard class_addMethod(NSWindow.self, marker, imp_implementationWithBlock(noop), "v16@0:8") else { return }
        let state = MotionDragMarginProbe()
        wrap("_updateStructuralRegionsOnNextDisplayCycle") { body in
            if MotionTrace.isEnabled {
                state.schedules += 1
                if state.callers.count < 3 { state.callers.append(firstAppFrame()) }
            }
            body()
        }
        wrap("_resetDragMargins") { body in
            guard MotionTrace.isEnabled else { return body() }
            let start = MotionTrace.now()
            body()
            MotionTrace.interval("zk.drm.s\(state.schedules).i\(state.invalidations).\(state.callers.joined(separator: "."))", since: start)
            state.schedules = 0
            state.invalidations = 0
            state.callers.removeAll()
        }
        let invalidate = #selector(NSWindow.invalidateCursorRects(for:))
        if let method = class_getInstanceMethod(NSWindow.self, invalidate) {
            let original = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector, NSView) -> Void
            let call = unsafeBitCast(original, to: Fn.self)
            let block: @convention(block) (AnyObject, NSView) -> Void = { this, view in
                // main-proof: AppKit invalidates cursor rects on the main thread
                MainActor.assumeIsolated {
                    if MotionTrace.isEnabled {
                        state.invalidations += 1
                        MotionTrace.interval("zk.icr.\(String(describing: type(of: view)))") {}
                    }
                }
                call(this, invalidate, view)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    /// Replaces the no-argument, no-result NSWindow method `name` with `around`, which calls the original as `body`.
    private static func wrap(_ name: String, _ around: @escaping @MainActor (() -> Void) -> Void) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(NSWindow.self, selector), let types = method_getTypeEncoding(method),
              String(cString: types).hasPrefix("v16@0:8") else { return }
        let original = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let call = unsafeBitCast(original, to: Fn.self)
        let block: @convention(block) (AnyObject) -> Void = { this in
            // main-proof: AppKit runs window structural regions on the main thread
            MainActor.assumeIsolated {
                around { call(this, selector) }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// The first two frames of cmux code above this probe and the window's invalidation forward, as one span-safe name.
    private static func firstAppFrame() -> String {
        let frames = Thread.callStackSymbols.compactMap { line -> String? in
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let address = tokens.firstIndex(where: { $0.hasPrefix("0x") }), address + 1 < tokens.count else { return nil }
            let symbol = tokens[address + 1]
            guard symbol.contains("CmuxNext"), !symbol.contains("DragMarginProbe"), !symbol.contains("invalidateCursorRects")
            else { return nil }
            return String(symbol.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(90))
        }
        let name = frames.prefix(2).joined(separator: "-")
        return name.isEmpty ? "none" : name
    }
}
#endif
