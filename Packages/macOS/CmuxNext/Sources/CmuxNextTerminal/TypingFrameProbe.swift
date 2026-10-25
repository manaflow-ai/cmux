import CmuxNextWakeups
import ObjectiveC
import QuartzCore

/// Marks ``TypingLatencyProbe/Mark/contents`` when Ghostty hands a finished
/// frame to its `IOSurfaceLayer` (`setContents:` on the main thread; Core
/// Animation commits it at the end of that run-loop turn). Installed only
/// while the probe is enabled: it adds a `setContents:` override to the
/// layer's runtime class that calls its superclass's and then marks. DEBUG builds
/// also install it for a `debug.new_terminal_trace` run (``NewTerminalTrace``),
/// whose `first_contents` and `prompt_contents` marks it makes. Once installed it
/// stays for the process and its layer class: each frame then pays the override's
/// call and the probes' armed checks. The override looks the superclass's IMP up
/// on each call, so a hook installed there later (RenderStats) runs while it is
/// in and never after it is out.
enum TypingFrameProbe {
    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    @MainActor private static var installed: Set<ObjectIdentifier> = []

    @MainActor static func install(on layer: CALayer) {
        let layerClass: AnyClass = type(of: layer)
        guard layerClass != CALayer.self, installed.insert(ObjectIdentifier(layerClass)).inserted,
              let superclass = class_getSuperclass(layerClass) else { return }
        let selector = #selector(setter: CALayer.contents)
        guard let inherited = class_getInstanceMethod(superclass, selector) else { return }
        class_addMethod(layerClass, selector, imp_implementationWithBlock(override(calling: superclass, selector)),
                        method_getTypeEncoding(inherited))
    }

    /// Built outside the main actor so the block carries no isolation check:
    /// a layer whose contents are set off the main thread must not trap.
    private nonisolated static func override(calling superclass: AnyClass, _ selector: Selector)
        -> @convention(block) (AnyObject, AnyObject?) -> Void {
        { layer, contents in
            if let imp = class_getMethodImplementation(superclass, selector) {
                unsafeBitCast(imp, to: SetContents.self)(layer, selector, contents)
            }
            TypingLatencyProbe.shared.mark(.contents)
            #if DEBUG || CMUX_BENCH_HOOKS
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: ObjectIdentifier(layer)) }
            #endif
        }
    }
}
