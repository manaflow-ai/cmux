import AppKit
import ObjectiveC
import QuartzCore

#if DEBUG || CMUX_BENCH_HOOKS
private typealias PlainIMP = @convention(c) (NSView, Selector) -> Void
private typealias RectIMP = @convention(c) (NSView, Selector, NSRect) -> Void
private typealias SizeIMP = @convention(c) (NSView, Selector, NSSize) -> Void
private typealias PointIMP = @convention(c) (NSView, Selector, NSPoint) -> Void
private typealias TrackingIMP = @convention(c) (NSView, Selector, NSTrackingArea) -> Void
private typealias ContentsIMP = @convention(c) (CALayer, Selector, AnyObject?) -> Void
private typealias WindowFrameIMP = @convention(c) (NSWindow, Selector, NSRect, ObjCBool) -> Void
private typealias AlphaIMP = @convention(c) (NSWindow, Selector, CGFloat) -> Void

extension RenderStats {
    /// One replaced method: armed it runs `replacement`, disarmed `original`.
    struct Hook {
        let method: Method
        let original: IMP
        let replacement: IMP
    }

    /// The hooks of one scan and the generation their blocks count for.
    struct HookSet {
        var hooks: [Hook] = []
        var generation = 0
    }

    /// The classes that define one hooked selector themselves (by ``classKey(_:)``).
    nonisolated struct Definers: Sendable {
        let classes: Set<ObjectIdentifier>

        /// No hooked class lies between the receiver's class and `owner`: the
        /// call is the outermost hooked one (an override calling `super` counts once).
        func isOutermost(_ object: AnyObject, at owner: ObjectIdentifier) -> Bool {
            var next: AnyClass? = object_getClass(object)
            while let type = next {
                let key = classKey(type)
                if key == owner { return true }
                if classes.contains(key) { return false }
                next = class_getSuperclass(type)
            }
            return true
        }
    }

    /// One identity per class: its Objective-C class object. A metatype of a
    /// pure Objective-C class is Swift's wrapper metadata when Swift made it
    /// (`NSView.self`, `class_getSuperclass`) and the class itself when read from
    /// the runtime's class list, so `ObjectIdentifier` of the metatype differs
    /// between the two. Only for NSObject classes (the bridge retains the class object).
    nonisolated static func classKey(_ type: AnyClass) -> ObjectIdentifier {
        ObjectIdentifier(type as AnyObject)
    }

    static let hookedSelectors: [(root: AnyClass, selectors: [Selector])] = [
        (NSView.self, [#selector(NSView.setFrameSize(_:)), #selector(NSView.setFrameOrigin(_:)), #selector(NSView.updateLayer),
                       #selector(NSView.draw(_:)), #selector(NSView.addTrackingArea(_:))]),
        (CALayer.self, [#selector(setter: CALayer.contents)]),
        (NSWindow.self, [#selector(NSWindow.setFrame(_:display:)), #selector(setter: NSWindow.alphaValue)]),
    ]

    /// The hooks for the classes loaded now: `previous` when the same methods
    /// still have the IMPs it replaces, else a new set of a new generation (the
    /// old blocks, should another swizzler still call one, stop counting).
    static func hooks(reusing previous: HookSet, ledger: Ledger) -> HookSet {
        let definers = scanDefiners()
        let methods = Set(definers.values.flatMap { $0.map(\.method) })
        if !previous.hooks.isEmpty, Set(previous.hooks.map(\.method)) == methods,
           previous.hooks.allSatisfy({ method_getImplementation($0.method) == $0.original }) {
            return previous
        }
        var set = HookSet(generation: previous.generation + 1)
        for (selector, entries) in definers {
            let chain = Definers(classes: Set(entries.map { classKey($0.type) }))
            for entry in entries {
                let original = method_getImplementation(entry.method)
                let hook = RenderCountingHook(ledger: ledger, generation: set.generation, chain: chain, owner: classKey(entry.type))
                guard let block = hook.block(for: selector, calling: original) else { continue }
                set.hooks.append(Hook(method: entry.method, original: original, replacement: imp_implementationWithBlock(block)))
            }
        }
        return set
    }

    /// Each root and every loaded class under it that defines a hooked selector
    /// itself. Reads the class list with C calls only (no message to a class
    /// before it is known to be under a root).
    private static func scanDefiners() -> [Selector: [(type: AnyClass, method: Method)]] {
        var definers: [Selector: [(type: AnyClass, method: Method)]] = [:]
        func add(_ type: AnyClass, _ selectors: [Selector]) {
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(type, &methodCount) else { return }
            defer { free(methods) }
            for method in UnsafeBufferPointer(start: methods, count: Int(methodCount)) where selectors.contains(method_getName(method)) {
                definers[method_getName(method), default: []].append((type, method))
            }
        }
        for entry in hookedSelectors {
            // A lookup resolves a method the class adds lazily, so its method list has it.
            for selector in entry.selectors { _ = class_getInstanceMethod(entry.root, selector) }
            add(entry.root, entry.selectors)
        }
        var classCount: UInt32 = 0
        guard let list = objc_copyClassList(&classCount) else { return [:] }
        let raw = UnsafeMutableRawPointer(list)
        defer { free(raw) }
        // Read as raw pointers: the autoreleasing list retains what it reads, and a root class without
        // `retain` (JSExport) aborts. A metatype is not reference counted.
        let classes = raw.assumingMemoryBound(to: UnsafeRawPointer.self)
        for index in 0..<Int(classCount) {
            let type = unsafeBitCast(classes[index], to: AnyClass.self)
            guard let selectors = hookedSelectors.first(where: { isSubclass(type, of: $0.root) })?.selectors else { continue }
            add(type, selectors)
        }
        return definers
    }

    /// Whether `root` is a strict superclass of `type`. Compares the
    /// superclasses only: they come from the runtime as Swift-made metatypes,
    /// like `root`; `type` itself is a class-list entry (see ``classKey(_:)``).
    private static func isSubclass(_ type: AnyClass, of root: AnyClass) -> Bool {
        let rootID = ObjectIdentifier(root)
        var next: AnyClass? = class_getSuperclass(type)
        while let current = next {
            if ObjectIdentifier(current) == rootID { return true }
            next = class_getSuperclass(current)
        }
        return false
    }
}

/// The counting replacement of one hooked method on one class (`owner`).
/// Nonisolated so its blocks carry no isolation check: a call off the main
/// thread must not trap. Frame, window and `updateLayer` calls read view
/// state, so they count on the main thread only.
nonisolated struct RenderCountingHook {
    let ledger: RenderStats.Ledger
    let generation: Int
    let chain: RenderStats.Definers
    let owner: ObjectIdentifier

    private func counts(_ object: AnyObject, onMainOnly: Bool) -> Bool {
        ledger.isArmed(generation: generation) && (!onMainOnly || Thread.isMainThread) && chain.isOutermost(object, at: owner)
    }

    /// The block for `imp_implementationWithBlock` that counts and calls `imp`; nil for a selector it does not know.
    func block(for selector: Selector, calling imp: IMP) -> Any? {
        switch selector {
        case #selector(NSView.setFrameSize(_:)):
            let original = unsafeBitCast(imp, to: SizeIMP.self)
            let block: @convention(block) (NSView, NSSize) -> Void = { view, size in
                guard counts(view, onMainOnly: true) else { return original(view, selector, size) }
                let changed = MainActor.assumeIsolated { view.frame.size != size } // main-proof: checked in counts
                original(view, selector, size)
                if changed { ledger.add(.frameSets, owner: Swift.type(of: view)) }
            }
            return block
        case #selector(NSView.setFrameOrigin(_:)):
            let original = unsafeBitCast(imp, to: PointIMP.self)
            let block: @convention(block) (NSView, NSPoint) -> Void = { view, origin in
                guard counts(view, onMainOnly: true) else { return original(view, selector, origin) }
                let changed = MainActor.assumeIsolated { view.frame.origin != origin } // main-proof: checked in counts
                original(view, selector, origin)
                if changed { ledger.add(.frameSets, owner: Swift.type(of: view)) }
            }
            return block
        case #selector(NSView.updateLayer):
            let original = unsafeBitCast(imp, to: PlainIMP.self)
            let block: @convention(block) (NSView) -> Void = { view in
                guard counts(view, onMainOnly: true) else { return original(view, selector) }
                original(view, selector)
                let size = MainActor.assumeIsolated { view.bounds.size } // main-proof: checked in counts
                ledger.add(.damageRects, owner: Swift.type(of: view))
                ledger.add(.damageArea, Int((size.width * size.height).rounded()), owner: Swift.type(of: view))
            }
            return block
        case #selector(NSView.draw(_:)):
            let original = unsafeBitCast(imp, to: RectIMP.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { view, dirty in
                let counted = counts(view, onMainOnly: false)
                original(view, selector, dirty)
                guard counted else { return }
                ledger.add(.damageRects, owner: Swift.type(of: view))
                ledger.add(.damageArea, Int((dirty.width * dirty.height).rounded()), owner: Swift.type(of: view))
            }
            return block
        case #selector(NSView.addTrackingArea(_:)):
            let original = unsafeBitCast(imp, to: TrackingIMP.self)
            let block: @convention(block) (NSView, NSTrackingArea) -> Void = { view, area in
                let counted = counts(view, onMainOnly: false)
                original(view, selector, area)
                if counted { ledger.add(.trackingAreaAdds, owner: Swift.type(of: view)) }
            }
            return block
        case #selector(setter: CALayer.contents):
            let original = unsafeBitCast(imp, to: ContentsIMP.self)
            let block: @convention(block) (CALayer, AnyObject?) -> Void = { layer, contents in
                guard counts(layer, onMainOnly: false) else { return original(layer, selector, contents) }
                let changed = layer.contents.map { $0 as AnyObject } !== contents
                original(layer, selector, contents)
                guard changed else { return }
                let owner: AnyObject = layer.delegate.map { $0 as AnyObject } ?? layer
                ledger.add(.contentsSets, owner: Swift.type(of: owner))
            }
            return block
        case #selector(NSWindow.setFrame(_:display:)):
            let original = unsafeBitCast(imp, to: WindowFrameIMP.self)
            let block: @convention(block) (NSWindow, NSRect, ObjCBool) -> Void = { window, frame, display in
                guard counts(window, onMainOnly: true) else { return original(window, selector, frame, display) }
                let changed = MainActor.assumeIsolated { window.frame != frame } // main-proof: checked in counts
                original(window, selector, frame, display)
                if changed { ledger.add(.windowCalls, owner: Swift.type(of: window)) }
            }
            return block
        case #selector(setter: NSWindow.alphaValue):
            let original = unsafeBitCast(imp, to: AlphaIMP.self)
            let block: @convention(block) (NSWindow, CGFloat) -> Void = { window, alpha in
                guard counts(window, onMainOnly: true) else { return original(window, selector, alpha) }
                let changed = MainActor.assumeIsolated { window.alphaValue != alpha } // main-proof: checked in counts
                original(window, selector, alpha)
                if changed { ledger.add(.windowCalls, owner: Swift.type(of: window)) }
            }
            return block
        default:
            return nil
        }
    }
}
#endif
