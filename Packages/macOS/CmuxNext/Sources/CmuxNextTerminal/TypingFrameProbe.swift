import CmuxNextWakeups
import ObjectiveC
import QuartzCore

/// The `setContents:` hook on terminal layer classes, in DEBUG and bench builds only: Ghostty hands
/// each finished frame to its `IOSurfaceLayer` there (on the main thread now; Core Animation commits it
/// at the end of that run-loop turn), from any thread once frames are set off main.
///
/// It goes on every terminal layer class: while some surface's key echo was parsed and its frame is
/// awaited (``TerminalContentsGate``), the frame marks that surface's ``TerminalEchoStage``, and while
/// the ``TypingLatencyProbe`` records, the frame is the ``TypingLatencyProbe/Mark/contents`` mark of the
/// presses open on the layer's surface (``TypingLatencyProbe/SurfaceKey``). Otherwise each frame pays
/// the override's call, the superclass IMP lookup and two relaxed loads. Release builds have no swizzle:
/// there the contents mark comes from the Ghostty trace hook's IOSurface handoff
/// (p09-observability-049). DEBUG builds also make a `debug.new_terminal_trace` run's `first_contents`
/// and `prompt_contents` marks here (``NewTerminalTrace``).
///
/// It adds a `setContents:` override to the layer's runtime class that calls its superclass's and then
/// marks; once installed it stays for the process and its layer class. The override looks the
/// superclass's IMP up on each call, so a hook installed there later (RenderStats) runs while it is
/// in and never after it is out.
enum TypingFrameProbe {
    /// Whether every terminal layer class gets the hook, and so whether surfaces get echo stages.
    nonisolated static var hooksEveryLayer: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        return true
        #else
        return false
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// Each hooked layer class and the gate its hook reads.
    @MainActor private static var installed: [ObjectIdentifier: TerminalContentsGate] = [:]

    /// A layer's surface to the typing probe, as an associated object.
    private nonisolated final class SurfaceBox: Sendable {
        let key: TypingLatencyProbe.SurfaceKey
        init(_ key: TypingLatencyProbe.SurfaceKey) { self.key = key }
    }

    /// The associated-object key of a layer's ``SurfaceBox``: the class object, one stable address
    /// readable from any thread.
    private nonisolated static var keyFlowsKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(SurfaceBox.self as AnyObject).toOpaque())
    }
    #endif

    /// Installs the hook on `layer`'s class, once per class, and ties `keyFlows` to `layer`. Its hook
    /// reads `gate`, so every install on a class must pass the process's gate
    /// (``GhosttyRuntime/echoStages``). Nothing in Release builds.
    @MainActor static func install(on layer: CALayer, gate: TerminalContentsGate,
                                   keyFlows: TypingLatencyProbe.SurfaceKey? = nil) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let keyFlows { objc_setAssociatedObject(layer, keyFlowsKey, SurfaceBox(keyFlows), .OBJC_ASSOCIATION_RETAIN) }
        let layerClass: AnyClass = type(of: layer)
        guard layerClass != CALayer.self else { return }
        if let hooked = installed[ObjectIdentifier(layerClass)] {
            assert(hooked === gate, "one contents gate per layer class: build TerminalEchoStages on the runtime's gate")
            return
        }
        installed[ObjectIdentifier(layerClass)] = gate
        guard let superclass = class_getSuperclass(layerClass) else { return }
        let selector = #selector(setter: CALayer.contents)
        guard let inherited = class_getInstanceMethod(superclass, selector) else { return }
        let hook = override(calling: superclass, selector, gate: gate)
        class_addMethod(layerClass, selector, imp_implementationWithBlock(hook), method_getTypeEncoding(inherited))
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Built outside the main actor so the block carries no isolation check:
    /// a layer whose contents are set off the main thread must not trap.
    private nonisolated static func override(calling superclass: AnyClass, _ selector: Selector,
                                             gate: TerminalContentsGate) -> @convention(block) (AnyObject, AnyObject?) -> Void {
        { layer, contents in
            if let imp = class_getMethodImplementation(superclass, selector) {
                unsafeBitCast(imp, to: SetContents.self)(layer, selector, contents)
            }
            if gate.isOpen { TerminalEchoStage.attached(to: layer)?.contentsSet() }
            if TypingLatencyProbe.isEnabled,
               let box = objc_getAssociatedObject(layer, keyFlowsKey) as? SurfaceBox {
                TypingLatencyProbe.shared.mark(.contents, surface: box.key)
            }
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: ObjectIdentifier(layer)) }
        }
    }
    #endif
}
