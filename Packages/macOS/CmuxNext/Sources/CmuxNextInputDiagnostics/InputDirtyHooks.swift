#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ObjectiveC
import QuartzCore

/// The input that started a turn.
nonisolated enum InputDirtyTurnKind: String, CaseIterable, Sendable {
    case key, click, scroll
}

/// A hooked dirty call.
nonisolated enum InputDirtyCall: UInt8, CaseIterable, Sendable {
    case viewNeedsDisplay, viewNeedsDisplayInRect, viewNeedsLayout, viewNeedsUpdateConstraints
    case layerNeedsLayout, layerNeedsDisplay, layerNeedsDisplayInRect

    private typealias FlagIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    private typealias RectIMP = @convention(c) (AnyObject, Selector, CGRect) -> Void
    private typealias PlainIMP = @convention(c) (AnyObject, Selector) -> Void

    /// The row's `call`.
    var name: String {
        switch self {
        case .viewNeedsDisplay: "view.needs_display"
        case .viewNeedsDisplayInRect: "view.needs_display_in_rect"
        case .viewNeedsLayout: "view.needs_layout"
        case .viewNeedsUpdateConstraints: "view.needs_update_constraints"
        case .layerNeedsLayout: "layer.needs_layout"
        case .layerNeedsDisplay: "layer.needs_display"
        case .layerNeedsDisplayInRect: "layer.needs_display_in_rect"
        }
    }

    var root: AnyClass {
        switch self {
        case .viewNeedsDisplay, .viewNeedsDisplayInRect, .viewNeedsLayout, .viewNeedsUpdateConstraints: NSView.self
        case .layerNeedsLayout, .layerNeedsDisplay, .layerNeedsDisplayInRect: CALayer.self
        }
    }

    var selector: Selector {
        switch self {
        case .viewNeedsDisplay: #selector(setter: NSView.needsDisplay)
        case .viewNeedsDisplayInRect: #selector(NSView.setNeedsDisplay(_:))
        case .viewNeedsLayout: #selector(setter: NSView.needsLayout)
        case .viewNeedsUpdateConstraints: #selector(setter: NSView.needsUpdateConstraints)
        case .layerNeedsLayout: #selector(CALayer.setNeedsLayout)
        case .layerNeedsDisplay: #selector(CALayer.setNeedsDisplay as (CALayer) -> () -> Void)
        case .layerNeedsDisplayInRect: #selector(CALayer.setNeedsDisplay(_:))
        }
    }

    /// The block implementation that records the call in `ledger` and sends it to `original`. A flag
    /// setter records only a `true`: `false` dirties nothing.
    func replacement(calling original: IMP, ledger: InputDirtyLedger) -> IMP {
        let selector = self.selector
        let call = self
        switch self {
        case .viewNeedsDisplay, .viewNeedsLayout, .viewNeedsUpdateConstraints:
            // SAFETY: `original` is the IMP of `selector`, a `(BOOL)` setter on NSView.
            let send = unsafe unsafeBitCast(original, to: FlagIMP.self)
            let block: @convention(block) (AnyObject, ObjCBool) -> Void = { receiver, flag in
                ledger.around(call, receiver, records: flag.boolValue) { send(receiver, selector, flag) }
            }
            return unsafe imp_implementationWithBlock(block)
        case .viewNeedsDisplayInRect, .layerNeedsDisplayInRect:
            // SAFETY: `original` is the IMP of `selector`, which takes one rect (NSRect is CGRect).
            let send = unsafe unsafeBitCast(original, to: RectIMP.self)
            let block: @convention(block) (AnyObject, CGRect) -> Void = { receiver, rect in
                ledger.around(call, receiver, records: true) { send(receiver, selector, rect) }
            }
            return unsafe imp_implementationWithBlock(block)
        case .layerNeedsLayout, .layerNeedsDisplay:
            // SAFETY: `original` is the IMP of `selector`, which takes no argument.
            let send = unsafe unsafeBitCast(original, to: PlainIMP.self)
            let block: @convention(block) (AnyObject) -> Void = { receiver in
                ledger.around(call, receiver, records: true) { send(receiver, selector) }
            }
            return unsafe imp_implementationWithBlock(block)
        }
    }
}

/// One replaced method while the recorder is installed. The runtime keeps the replacement's block,
/// and with it the ledger, for the process's life: the app makes one ledger.
nonisolated struct InputDirtyHook {
    let method: Method
    let original: IMP
    let replacement: IMP

    init?(call: InputDirtyCall, ledger: InputDirtyLedger) {
        guard let method = unsafe class_getInstanceMethod(call.root, call.selector) else { return nil }
        let original = unsafe method_getImplementation(method)
        unsafe self.method = method
        unsafe self.original = original
        unsafe replacement = call.replacement(calling: original, ledger: ledger)
    }
}
#endif
