import CmuxNextWakeups
import ObjectiveC
import QuartzCore

/// The `setContents:` hook on terminal layer classes, in DEBUG and bench builds only: Ghostty hands
/// each finished frame to its `IOSurfaceLayer` there (on the main thread now; Core Animation commits it
/// at the end of that run-loop turn), from any thread once frames are set off main.
///
/// It goes on every terminal layer class. While the linked libghostty has no trace hook
/// (``FrameSource/swizzle(_:)``), it is the frame source: while some surface's key echo was parsed and its
/// frame is awaited (``TerminalContentsGate``), the frame marks that surface's ``TerminalEchoStage``, and
/// while the ``TypingLatencyProbe`` records, the frame is the ``TypingLatencyProbe/Mark/contents`` mark of
/// the presses open on the layer's surface (``TypingLatencyProbe/SurfaceKey``). With the hook
/// (``FrameSource/traceHook``), its `CONTENTS_SET` is the only frame source, in
/// every build, so a frame is marked once and keeps its GPU wait; the override then only makes a
/// `debug.new_terminal_trace` run's `first_contents` and `prompt_contents` marks (``NewTerminalTrace``).
/// Otherwise each frame pays the override's call, the superclass IMP lookup and two relaxed loads.
///
/// It adds a `setContents:` override to the layer's runtime class that calls its superclass's and then
/// marks; once installed it stays for the process and its layer class. The override looks the
/// superclass's IMP up on each call, so a hook installed there later (RenderStats) runs while it is
/// in and never after it is out.
///
/// With renderer-owned frames (`GHOSTTY_RENDERER_FRAMES`) the renderer presents into
/// its own leaf and no frame passes through `setContents:`, so there is no hook in any build: every
/// contents mark, the new-terminal trace's too, is the renderer's presented-frame callback
/// (`presented_cb`, ``ghosttySurfacePresented(_:_:_:_:)``).
enum TypingFrameProbe {
    /// What marks a terminal frame for the echo stages and the typing probe.
    enum FrameSource {
        /// This override, marking `probe`: the linked libghostty has no trace hook.
        case swizzle(TypingLatencyProbe)
        /// The Ghostty trace hook (``GhosttyTraceHook``); the override marks neither.
        case traceHook
    }

    /// Whether every terminal layer class gets the hook, and so whether surfaces get echo stages.
    nonisolated static var hooksEveryLayer: Bool {
        #if (DEBUG || CMUX_BENCH_HOOKS) && !GHOSTTY_RENDERER_FRAMES
        return true
        #else
        return false
        #endif
    }

    #if (DEBUG || CMUX_BENCH_HOOKS) && !GHOSTTY_RENDERER_FRAMES
    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// Each hooked layer class and the gate its hook reads.
    @MainActor private static var installed: [ObjectIdentifier: TerminalContentsGate] = [:]

    /// A layer's surface to the typing probe, as an associated object.
    private nonisolated final class SurfaceBox: Sendable {
        let key: TypingLatencyProbe.SurfaceKey
        init(_ key: TypingLatencyProbe.SurfaceKey) { self.key = key }
    }

    /// The associated-object key of a layer's ``SurfaceBox``: the class's identity, one stable
    /// address readable from any thread (nil only for a 0 identity, which no type has).
    @safe private nonisolated static var keyFlowsKey: UnsafeRawPointer? {
        // SAFETY: built from the identity's bits and only compared by the runtime, never
        // dereferenced; the class's metadata lives for the process, so the address is stable.
        unsafe UnsafeRawPointer(bitPattern: UInt(bitPattern: ObjectIdentifier(SurfaceBox.self)))
    }
    #endif

    /// ``install(on:gate:keyFlows:frames:)`` with `stages`' gate, and the trace hook as the frame source when
    /// `stages`' hook is supported (the shared probe's swizzle otherwise).
    @MainActor static func install(on layer: CALayer, stages: TerminalEchoStages, keyFlows: TypingLatencyProbe.SurfaceKey) {
        install(on: layer, gate: stages.contentsGate, keyFlows: keyFlows,
                frames: stages.traceHook?.isSupported == true ? .traceHook : .swizzle(.shared))
    }

    /// Installs the hook on `layer`'s class, once per class, and ties `keyFlows` to `layer`. Its hook
    /// reads `gate`, so every install on a class must pass the process's gate
    /// (``GhosttyRuntime/echoStages``), and marks frames from the first install's `frames`. Nothing in
    /// Release builds.
    @MainActor static func install(on layer: CALayer, gate: TerminalContentsGate,
                                   keyFlows: TypingLatencyProbe.SurfaceKey? = nil, frames: FrameSource = .swizzle(.shared)) {
        #if (DEBUG || CMUX_BENCH_HOOKS) && !GHOSTTY_RENDERER_FRAMES
        if let keyFlows, let key = unsafe keyFlowsKey {
            // SAFETY: the key is an address the runtime only compares (`keyFlowsKey`); the runtime
            // retains the box on `layer` (OBJC_ASSOCIATION_RETAIN).
            unsafe objc_setAssociatedObject(layer, key, SurfaceBox(keyFlows), .OBJC_ASSOCIATION_RETAIN)
        }
        let layerClass: AnyClass = type(of: layer)
        guard layerClass != CALayer.self else { return }
        if let hooked = installed[ObjectIdentifier(layerClass)] {
            assert(hooked === gate, "one contents gate per layer class: build TerminalEchoStages on the runtime's gate")
            return
        }
        installed[ObjectIdentifier(layerClass)] = gate
        guard let superclass = class_getSuperclass(layerClass) else { return }
        let selector = #selector(setter: CALayer.contents)
        // SAFETY: the runtime's handle of the superclass's `setContents:`, which lives as long as
        // its class (the process); it is only passed back to the runtime below.
        guard let inherited = unsafe class_getInstanceMethod(superclass, selector) else { return }
        let marked: TypingLatencyProbe? = switch frames {
        case .swizzle(let probe): probe
        case .traceHook: nil
        }
        let hook = override(calling: superclass, selector, gate: gate, marks: marked)
        // SAFETY: `inherited` as above; its type encoding is a C string the runtime owns for the
        // process and class_addMethod copies. The block IMP has that encoding's signature,
        // (id, SEL, id) -> void, and the runtime keeps the block for the process.
        unsafe class_addMethod(layerClass, selector, imp_implementationWithBlock(hook), method_getTypeEncoding(inherited))
        #endif
    }

    #if (DEBUG || CMUX_BENCH_HOOKS) && !GHOSTTY_RENDERER_FRAMES
    /// Built outside the main actor so the block carries no isolation check:
    /// a layer whose contents are set off the main thread must not trap. `probe` nil: the trace hook marks.
    private nonisolated static func override(calling superclass: AnyClass, _ selector: Selector, gate: TerminalContentsGate,
                                             marks probe: TypingLatencyProbe?) -> @convention(block) (AnyObject, AnyObject?) -> Void {
        { layer, contents in
            // SAFETY: the runtime's IMP of the superclass's `setContents:`, valid for the process;
            // called only through its own signature below.
            if let imp = unsafe class_getMethodImplementation(superclass, selector) {
                // SAFETY: `imp` is the superclass's `setContents:`, an Objective-C method of type
                // (id, SEL, id) -> void, which SetContents is; it is called with that selector.
                unsafe unsafeBitCast(imp, to: SetContents.self)(layer, selector, contents)
            }
            if let probe {
                if gate.isOpen { TerminalEchoStage.attached(to: layer)?.contentsSet() }
                // SAFETY: the key is an address the runtime only compares (`keyFlowsKey`); the value is
                // an object the layer retains, and the cast checks its type.
                if probe.isRecording, let key = unsafe keyFlowsKey,
                   let box = unsafe objc_getAssociatedObject(layer, key) as? SurfaceBox {
                    probe.mark(.contents, surface: box.key)
                }
            }
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: ObjectIdentifier(layer)) }
        }
    }
    #endif
}
