#if DEBUG
import AppKit
import CmuxNextCompat
import CmuxNextSettings
import ObjectiveC

/// `debug.view_churn {action: start | stop, limit}` (DEBUG builds): which views change the window's view
/// or layer tree, or ask for display or layout, while it runs (perf-lead.md issue 5: the display cycle
/// rebuilt layer trees on keys and under load, `NSViewBuildLayerTreeForDisplay` 15-21 % of the main
/// thread). Counts per view class: subviews added and removed, hidden flips, `wantsLayer` changes,
/// `needsDisplay`, `needsLayout` and frame size changes. `stop` returns the top `limit` classes per kind.
/// Installed on the first `start` by replacing `NSView`'s implementations with counting ones that call
/// the original; afterwards each call pays one flag check while not counting.
@MainActor
enum DebugViewChurn {
    private static var counting = false
    /// ``counting`` for the replaced methods, read off the main actor: one relaxed load per call while off.
    nonisolated private static let active = Atomic<Bool>(false)
    private static var installed = false
    private static var counts: [String: [String: Int]] = [:]
    private static var started = ContinuousClock.now

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "stop" {
        case "start":
            install()
            counts = [:]
            started = .now
            counting = true
            active.store(true, ordering: .relaxed)
            return .object(["ok": .bool(true)])
        default:
            counting = false
            active.store(false, ordering: .relaxed)
            let limit = params["limit"]?.intValue ?? 25
            let elapsed = ContinuousClock.now - started
            var kinds: [String: JSONValue] = [:]
            for (kind, perClass) in counts {
                let top = perClass.sorted { $0.value > $1.value }.prefix(limit)
                kinds[kind] = .object([
                    "total": .number(Double(perClass.values.reduce(0, +))),
                    "top": .array(top.map { .object(["class": .string($0.key), "count": .number(Double($0.value))]) }),
                ])
            }
            return .object(["seconds": .number(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18),
                            "kinds": .object(kinds)])
        }
    }

    /// Counts one call of `kind` on `view` (main thread only; a call off main is not counted).
    nonisolated fileprivate static func note(_ kind: String, _ view: AnyObject) {
        guard active.load(ordering: .relaxed), Thread.isMainThread else { return }
        let name = String(cString: class_getName(object_getClass(view)))
        MainActor.assumeIsolated { // main-proof: checked Thread.isMainThread above
            guard counting else { return }
            counts[kind, default: [:]][name, default: 0] += 1
        }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        swizzle(#selector(NSView.addSubview(_:)), kind: "addSubview", as: ObjectArg.self)
        swizzle(#selector(NSView.addSubview(_:positioned:relativeTo:)), kind: "addSubview", as: AddPositioned.self)
        swizzle(#selector(NSView.removeFromSuperview), kind: "removeFromSuperview", as: NoArg.self)
        swizzle(#selector(setter: NSView.isHidden), kind: "setHidden", as: BoolArg.self)
        swizzle(#selector(setter: NSView.wantsLayer), kind: "setWantsLayer", as: BoolArg.self)
        swizzle(#selector(setter: NSView.needsDisplay), kind: "needsDisplay", as: BoolArg.self)
        swizzle(#selector(NSView.setNeedsDisplay(_:)), kind: "needsDisplayInRect", as: RectArg.self)
        swizzle(#selector(setter: NSView.needsLayout), kind: "needsLayout", as: BoolArg.self)
        swizzle(#selector(NSView.setFrameSize(_:)), kind: "setFrameSize", as: SizeArg.self)
    }

    private typealias NoArg = @convention(c) (AnyObject, Selector) -> Void
    private typealias ObjectArg = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias BoolArg = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias RectArg = @convention(c) (AnyObject, Selector, NSRect) -> Void
    private typealias SizeArg = @convention(c) (AnyObject, Selector, NSSize) -> Void
    private typealias AddPositioned = @convention(c) (AnyObject, Selector, AnyObject?, Int, AnyObject?) -> Void

    private static func swizzle<F>(_ selector: Selector, kind: String, as _: F.Type) {
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let original = method_getImplementation(method)
        let block = counter(original, selector, kind, F.self)
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Built outside the main actor so the blocks carry no isolation check (AppKit can call these off main).
    nonisolated private static func counter<F>(_ original: IMP, _ selector: Selector, _ kind: String, _: F.Type) -> Any {
        switch F.self {
        case is NoArg.Type:
            let call = unsafeBitCast(original, to: NoArg.self)
            return { (view: AnyObject) in note(kind, view); call(view, selector) } as @convention(block) (AnyObject) -> Void
        case is ObjectArg.Type:
            let call = unsafeBitCast(original, to: ObjectArg.self)
            return { (view: AnyObject, a: AnyObject?) in note(kind, view); call(view, selector, a) } as @convention(block) (AnyObject, AnyObject?) -> Void
        case is BoolArg.Type:
            let call = unsafeBitCast(original, to: BoolArg.self)
            return { (view: AnyObject, a: Bool) in note(kind, view); call(view, selector, a) } as @convention(block) (AnyObject, Bool) -> Void
        case is RectArg.Type:
            let call = unsafeBitCast(original, to: RectArg.self)
            return { (view: AnyObject, a: NSRect) in note(kind, view); call(view, selector, a) } as @convention(block) (AnyObject, NSRect) -> Void
        case is SizeArg.Type:
            let call = unsafeBitCast(original, to: SizeArg.self)
            return { (view: AnyObject, a: NSSize) in note(kind, view); call(view, selector, a) } as @convention(block) (AnyObject, NSSize) -> Void
        default:
            let call = unsafeBitCast(original, to: AddPositioned.self)
            return { (view: AnyObject, a: AnyObject?, b: Int, c: AnyObject?) in note(kind, view); call(view, selector, a, b, c) }
                as @convention(block) (AnyObject, AnyObject?, Int, AnyObject?) -> Void
        }
    }
}
#endif
