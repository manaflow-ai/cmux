import CmuxNextWakeups
import ObjectiveC
import QuartzCore

/// Marks ``TypingLatencyProbe/Mark/contents`` when Ghostty hands a finished
/// frame to its `IOSurfaceLayer` (`setContents:` on the main thread; Core
/// Animation commits it at the end of that run-loop turn). Installed only
/// while the probe is enabled: it adds a `setContents:` override to the
/// layer's runtime class that calls `CALayer`'s and then marks. DEBUG builds
/// also install it for a `debug.new_terminal_trace` run (``NewTerminalTrace``),
/// whose `first_contents` and `prompt_contents` marks it makes. Once installed it
/// stays for the process and its layer class: each frame then pays the override's
/// call and the probes' armed checks. A terminal that predicts its echo
/// (``TerminalEchoPredictor``) installs it too, and its layer then tells its
/// prediction engine of each frame (``watchPresents(of:for:)``): held
/// confirmations retire with the frame that shows the echo.
enum TypingFrameProbe {
    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    @MainActor private static var installed: Set<ObjectIdentifier> = []

    @MainActor static func install(on layer: CALayer) {
        let layerClass: AnyClass = type(of: layer)
        guard layerClass != CALayer.self, installed.insert(ObjectIdentifier(layerClass)).inserted else { return }
        let selector = #selector(setter: CALayer.contents)
        guard let inherited = class_getInstanceMethod(CALayer.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(inherited), to: SetContents.self)
        class_addMethod(layerClass, selector, imp_implementationWithBlock(override(calling: original, selector)),
                        method_getTypeEncoding(inherited))
    }

    /// Tells `prediction` of each frame `layer` presents, from the thread that sets its contents. The engine is
    /// held by the layer, so it lives while the surface's frames still come.
    @MainActor static func watchPresents(of layer: CALayer, for prediction: TerminalEchoPrediction) {
        objc_setAssociatedObject(layer, presentsKey, prediction, .OBJC_ASSOCIATION_RETAIN)
        install(on: layer)
    }

    /// The key of the engine a layer tells of its frames: the engine class's own address, the same for every call.
    private nonisolated static var presentsKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(TerminalEchoPrediction.self as AnyObject).toOpaque())
    }

    /// Built outside the main actor so the block carries no isolation check:
    /// a layer whose contents are set off the main thread must not trap.
    private nonisolated static func override(calling original: SetContents, _ selector: Selector)
        -> @convention(block) (AnyObject, AnyObject?) -> Void {
        { layer, contents in
            original(layer, selector, contents)
            (objc_getAssociatedObject(layer, presentsKey) as? TerminalEchoPrediction)?.presentedFrame()
            TypingLatencyProbe.shared.mark(.contents, source: .object(ObjectIdentifier(layer)))
            #if DEBUG || CMUX_BENCH_HOOKS
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: ObjectIdentifier(layer)) }
            #endif
        }
    }
}
