#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ObjectiveC
import QuartzCore

private typealias FlagIMP = @convention(c) (NSView, Selector, ObjCBool) -> Void
private typealias ViewRectIMP = @convention(c) (NSView, Selector, NSRect) -> Void
private typealias LayerIMP = @convention(c) (CALayer, Selector) -> Void
private typealias LayerRectIMP = @convention(c) (CALayer, Selector, CGRect) -> Void

/// The replacement of one dirty method for ``InputDirtyRecorder``: it tells the recorder on the
/// main thread, then calls the method's previous IMP. Nonisolated so its blocks carry no isolation
/// check: AppKit and Core Animation call these from other threads too, and such a call only passes
/// through.
nonisolated struct InputDirtyHook {
    /// One replaced method.
    nonisolated struct Installed {
        let method: Method
        let original: IMP
        let replacement: IMP
    }

    weak var recorder: InputDirtyRecorder?
    let generation: Int
    let kind: InputDirtyRecorder.DirtyKind

    /// Replaces every hooked method that its root class defines itself (never one it inherits:
    /// that IMP is its superclass's) with a hook of `generation`.
    static func install(recorder: InputDirtyRecorder, generation: Int) -> [Installed] {
        InputDirtyRecorder.DirtyKind.allCases.compactMap { kind in
            let root: AnyClass = kind.root
            guard let method = class_getInstanceMethod(root, kind.selector),
                  class_getSuperclass(root).flatMap({ class_getInstanceMethod($0, kind.selector) }) != method else { return nil }
            let original = method_getImplementation(method)
            let hook = InputDirtyHook(recorder: recorder, generation: generation, kind: kind)
            let replacement = imp_implementationWithBlock(hook.block(calling: original))
            method_setImplementation(method, replacement)
            return Installed(method: method, original: original, replacement: replacement)
        }
    }

    /// Puts each original IMP back where the method still runs its replacement. A swizzler that
    /// chained onto a hook keeps it, and the hook's generation check stops the recording. The
    /// blocks are never released: a call on another thread may be running one.
    static func uninstall(_ hooks: [Installed]) {
        for hook in hooks where method_getImplementation(hook.method) == hook.replacement {
            method_setImplementation(hook.method, hook.original)
        }
    }

    /// The block for `imp_implementationWithBlock` that records and calls `imp`.
    private func block(calling imp: IMP) -> Any {
        let selector = kind.selector
        switch kind {
        case .viewNeedsDisplay, .viewNeedsLayout, .viewNeedsUpdateConstraints:
            let original = unsafeBitCast(imp, to: FlagIMP.self)
            let block: @convention(block) (NSView, ObjCBool) -> Void = { view, flag in
                // A clearing set dirties nothing.
                guard flag.boolValue, enter(view) else { return original(view, selector, flag) }
                original(view, selector, flag)
                leave()
            }
            return block
        case .viewNeedsDisplayInRect:
            let original = unsafeBitCast(imp, to: ViewRectIMP.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { view, rect in
                guard enter(view) else { return original(view, selector, rect) }
                original(view, selector, rect)
                leave()
            }
            return block
        case .layerNeedsDisplay, .layerNeedsLayout:
            let original = unsafeBitCast(imp, to: LayerIMP.self)
            let block: @convention(block) (CALayer) -> Void = { layer in
                guard enter(layer) else { return original(layer, selector) }
                original(layer, selector)
                leave()
            }
            return block
        case .layerNeedsDisplayInRect:
            let original = unsafeBitCast(imp, to: LayerRectIMP.self)
            let block: @convention(block) (CALayer, CGRect) -> Void = { layer, rect in
                guard enter(layer) else { return original(layer, selector, rect) }
                original(layer, selector, rect)
                leave()
            }
            return block
        }
    }

    /// Tells the recorder a call starts; true when it must hear ``leave()`` after the original.
    /// The receiver (a layer is not Sendable) crosses into the main-actor closure as an unretained
    /// reference's bits: it is the running call's `self`, alive until that call returns.
    private func enter(_ object: AnyObject) -> Bool {
        guard Thread.isMainThread, let recorder else { return false }
        let receiver = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        let kind = kind
        let generation = generation
        // main-proof: Thread.isMainThread was checked above.
        return MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: receiver) else { return false }
            return recorder.enter(kind, Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue(), generation: generation)
        }
    }

    /// Tells the recorder the call that ``enter(_:)`` let through returned (on the main thread).
    private func leave() {
        guard let recorder else { return }
        // main-proof: only reached after enter(_:) returned true, which it does on the main thread only.
        MainActor.assumeIsolated { recorder.leave() }
    }
}
#endif
