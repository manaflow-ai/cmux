import CmuxNextWakeups
import ObjectiveC
import QuartzCore

/// The `setContents:` hook on every terminal layer class: Ghostty hands each finished frame to its
/// `IOSurfaceLayer` there (on the main thread now; Core Animation commits it at the end of that
/// run-loop turn), from any thread once frames are set off main.
///
/// Every build: while some surface's key echo was parsed and its frame is awaited
/// (``TerminalContentsGate``), the frame marks that surface's ``TerminalEchoStage``; otherwise the
/// hook costs one relaxed load of the gate after the superclass's call. With
/// `CMUX_NEXT_TYPING_PROBE` or `CMUX_NEXT_TRACE_FLOWS` set it also marks
/// ``TypingLatencyProbe/Mark/contents``, and DEBUG builds make a `debug.new_terminal_trace` run's
/// `first_contents` and `prompt_contents` marks (``NewTerminalTrace``).
///
/// It adds a `setContents:` override to the layer's runtime class that calls its superclass's and then
/// marks; once installed it stays for the process and its layer class. The override looks the
/// superclass's IMP up on each call, so a hook installed there later (RenderStats) runs while it is
/// in and never after it is out.
enum TypingFrameProbe {
    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    @MainActor private static var installed: Set<ObjectIdentifier> = []

    /// Installs the hook on `layer`'s class (once per class; the first install's `gate` is the class's).
    @MainActor static func install(on layer: CALayer, gate: TerminalContentsGate) {
        let layerClass: AnyClass = type(of: layer)
        guard layerClass != CALayer.self, installed.insert(ObjectIdentifier(layerClass)).inserted,
              let superclass = class_getSuperclass(layerClass) else { return }
        let selector = #selector(setter: CALayer.contents)
        guard let inherited = class_getInstanceMethod(superclass, selector) else { return }
        let hook = override(calling: superclass, selector, gate: gate, probes: TypingLatencyProbe.isEnabled)
        class_addMethod(layerClass, selector, imp_implementationWithBlock(hook), method_getTypeEncoding(inherited))
    }

    /// Built outside the main actor so the block carries no isolation check:
    /// a layer whose contents are set off the main thread must not trap.
    private nonisolated static func override(calling superclass: AnyClass, _ selector: Selector,
                                             gate: TerminalContentsGate, probes: Bool)
        -> @convention(block) (AnyObject, AnyObject?) -> Void {
        { layer, contents in
            if let imp = class_getMethodImplementation(superclass, selector) {
                unsafeBitCast(imp, to: SetContents.self)(layer, selector, contents)
            }
            if gate.isOpen { TerminalEchoStage.attached(to: layer)?.contentsSet() }
            if probes { TypingLatencyProbe.shared.mark(.contents) }
            #if DEBUG || CMUX_BENCH_HOOKS
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: ObjectIdentifier(layer)) }
            #endif
        }
    }
}
