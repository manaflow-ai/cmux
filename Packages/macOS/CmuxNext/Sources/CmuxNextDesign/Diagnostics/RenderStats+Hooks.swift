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
    ///
    /// Memory safety: `method` is a runtime method record, which the runtime
    /// never frees, so it stays valid for the process's life.
    // crash-allow: three immutable runtime handles; a Method and an IMP stay valid for the process's life.
    @safe nonisolated struct Hook: @unchecked Sendable {
        let method: Method
        let original: IMP
        let replacement: IMP
    }

    /// Sets each method to its replacement (`in`), or back to its original
    /// where it still runs the replacement (a swizzler that chained onto a hook
    /// keeps it, and its generation check stops the counting). Off the main
    /// thread: each set flushes method caches.
    @concurrent
    nonisolated static func swap(_ hooks: [Hook], in installing: Bool) async {
        for (index, hook) in hooks.enumerated() {
            if index % 256 == 255 { await Task.yield() }
            // SAFETY: hook.method is a live method record (see Hook), and both IMPs take its arguments.
            if installing {
                unsafe method_setImplementation(hook.method, hook.replacement)
            } else if unsafe method_getImplementation(hook.method) == hook.replacement {
                unsafe method_setImplementation(hook.method, hook.original)
            }
        }
    }

    /// The installed hooks and the generation their blocks count for.
    struct HookSet {
        var hooks: [Hook] = []
        var generation = 0
    }

    /// One method the hooks replace: on `root` too, or on its subclasses only.
    nonisolated struct HookedMethod {
        let root: AnyClass
        let selector: Selector
        let onRoot: Bool
    }

    /// The hooked methods, in ``ClassScan/definers`` order.
    nonisolated static func hookedMethods() -> [HookedMethod] {
        [
            HookedMethod(root: NSView.self, selector: #selector(NSView.setFrameSize(_:)), onRoot: true),
            HookedMethod(root: NSView.self, selector: #selector(NSView.setFrameOrigin(_:)), onRoot: true),
            HookedMethod(root: NSView.self, selector: #selector(NSView.addTrackingArea(_:)), onRoot: true),
            HookedMethod(root: NSView.self, selector: #selector(NSView.updateLayer), onRoot: false),
            HookedMethod(root: NSView.self, selector: #selector(NSView.draw(_:)), onRoot: false),
            HookedMethod(root: CALayer.self, selector: #selector(setter: CALayer.contents), onRoot: true),
            HookedMethod(root: NSWindow.self, selector: #selector(NSWindow.setFrame(_:display:)), onRoot: true),
            HookedMethod(root: NSWindow.self, selector: #selector(setter: NSWindow.alphaValue), onRoot: true),
        ]
    }

    /// One class that defines a hooked method itself: its ``classKey(_:)`` and its `Method`'s address.
    nonisolated struct Definer: Sendable, Hashable {
        let key: UInt
        let method: UInt
    }

    /// Per hooked method (``hookedMethods()`` order), the classes that define it, and the class count it saw.
    nonisolated struct ClassScan: Sendable {
        let classCount: Int32
        let definers: [[Definer]]
    }

    /// The classes that define one hooked method (by ``classKey(_:)``).
    nonisolated struct Definers: Sendable {
        let classes: Set<UInt>

        /// No hooked class lies between the receiver's class and `owner`: the
        /// call is the outermost hooked one (an override calling `super` counts once).
        func isOutermost(_ object: AnyObject, at owner: UInt) -> Bool {
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

    /// The scan of every loaded class, or nil when the runtime still has
    /// `count` classes. Runs off the main thread and yields as it goes. It
    /// reads the class list as raw pointers and sends no message (a retain
    /// included) to a class it has not placed under a root: a root class
    /// without `retain` (JSExport) aborts on one.
    @concurrent
    nonisolated static func scanClasses(unlessCountIs count: Int32?) async -> ClassScan? {
        let classCount = objc_getClassList(nil, 0)
        if let count, count == classCount { return nil }
        let methods = hookedMethods()
        var roots = RootIndex()
        for (index, method) in methods.enumerated() {
            roots.add(method.root, index: index)
            // A lookup resolves a method the root adds lazily, so its method list has it.
            // SAFETY: the record it returns is not used.
            _ = unsafe class_getInstanceMethod(method.root, method.selector)
        }
        var definers = [[Definer]](repeating: [], count: methods.count)
        var listCount: UInt32 = 0
        // SAFETY: objc_copyClassList writes the list's length into the local `listCount` and returns a malloc'd
        // array of that many class pointers that the caller frees (objc/runtime.h); it is read as raw pointers
        // (no retain) only below `listCount`, and freed once by the defer.
        guard let list = unsafe objc_copyClassList(&listCount) else { return ClassScan(classCount: classCount, definers: definers) }
        let raw = unsafe UnsafeMutableRawPointer(list)
        defer { unsafe free(raw) }
        let classes = unsafe raw.assumingMemoryBound(to: UnsafeRawPointer.self)
        for position in 0..<Int(listCount) {
            if position % 1_024 == 1_023 { await Task.yield() }
            // SAFETY: position < listCount (the loop's range): an entry of the list, a live class pointer.
            let key = unsafe UInt(bitPattern: classes[position])
            let type = unsafe unsafeBitCast(classes[position], to: AnyClass.self)
            let root = roots.indexes[key] != nil ? key : roots.root(above: type)
            guard let hooked = roots.indexes[root] else { continue }
            var methodCount: UInt32 = 0
            // SAFETY: class_copyMethodList writes the count into the local `methodCount` and returns a malloc'd
            // array of that many method records that the caller frees; it is read within the count and freed once.
            guard let methodList = unsafe class_copyMethodList(type, &methodCount) else { continue }
            defer { unsafe free(methodList) }
            for unsafe method in unsafe UnsafeBufferPointer(start: methodList, count: Int(methodCount)) {
                let name = unsafe method_getName(method)
                let address = UInt(bitPattern: method)
                for slot in hooked where methods[slot].selector == name && (key != root || methods[slot].onRoot) {
                    definers[slot].append(Definer(key: key, method: address))
                }
            }
        }
        return ClassScan(classCount: classCount, definers: definers)
    }

    /// The hooked roots by ``classKey(_:)``, and which root each class lies under.
    nonisolated struct RootIndex {
        /// Per root key, its methods' indexes in ``hookedMethods()``.
        private(set) var indexes: [UInt: [Int]] = [:]
        /// Per metatype (`class_getSuperclass` gives metatypes), its root's key, 0 for none.
        private var under: [ObjectIdentifier: UInt] = [:]

        mutating func add(_ root: AnyClass, index: Int) {
            indexes[classKey(root), default: []].append(index)
            under[ObjectIdentifier(root)] = classKey(root)
        }

        /// The key of the root above `type`, 0 for none.
        mutating func root(above type: AnyClass) -> UInt {
            var walked: [ObjectIdentifier] = []
            var next: AnyClass? = class_getSuperclass(type)
            var found: UInt = 0
            while let current = next {
                let id = ObjectIdentifier(current)
                if let known = under[id] { found = known; break }
                walked.append(id)
                next = class_getSuperclass(current)
            }
            for id in walked { under[id] = found }
            return found
        }
    }

    /// The hooks for `scan`: the installed set when the same methods still
    /// have the IMPs it replaces, else a new set of a new generation (the old
    /// blocks, should another swizzler still call one, stop counting).
    func makeHooks(for scan: ClassScan) -> HookSet {
        let methods = Self.hookedMethods()
        let wanted = Set(scan.definers.joined().map(\.method))
        // SAFETY: every hook's method is a live method record (see Hook).
        if !hooks.hooks.isEmpty, Set(hooks.hooks.map { unsafe UInt(bitPattern: $0.method) }) == wanted,
           hooks.hooks.allSatisfy({ unsafe method_getImplementation($0.method) == $0.original }) {
            return hooks
        }
        var set = HookSet(generation: hooks.generation + 1)
        for (index, list) in scan.definers.enumerated() where index < methods.count {
            let chain = Definers(classes: Set(list.map(\.key)))
            for definer in list {
                let hook = RenderCountingHook(ledger: ledger, generation: set.generation, chain: chain, owner: definer.key)
                // SAFETY: definer.method is the address of a method record the class scan read, and the runtime never
                // frees one (see Hook); its IMP takes the selector's arguments, which the block casts it to.
                guard let method = unsafe Method(bitPattern: definer.method) else { continue }
                let original = unsafe method_getImplementation(method)
                guard let block = unsafe hook.block(for: methods[index].selector, calling: original) else { continue }
                unsafe set.hooks.append(Hook(method: method, original: original, replacement: imp_implementationWithBlock(block)))
            }
        }
        return set
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
    let owner: UInt

    private func counts(_ object: AnyObject, onMainOnly: Bool) -> Bool {
        ledger.isArmed(generation: generation) && (!onMainOnly || Thread.isMainThread) && chain.isOutermost(object, at: owner)
    }

    /// The block for `imp_implementationWithBlock` that counts and calls `imp`; nil for a selector it does not know.
    func block(for selector: Selector, calling imp: IMP) -> Any? {
        switch selector {
        case #selector(NSView.setFrameSize(_:)):
            // SAFETY: `imp` implements -setFrameSize:(NSSize), a void method; SizeIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: SizeIMP.self)
            let block: @convention(block) (NSView, NSSize) -> Void = { view, size in
                guard counts(view, onMainOnly: true) else { return original(view, selector, size) }
                let changed = MainActor.assumeIsolated { view.frame.size != size } // main-proof: checked in counts
                original(view, selector, size)
                if changed { ledger.add(.frameSets, owner: Swift.type(of: view)) }
            }
            return block
        case #selector(NSView.setFrameOrigin(_:)):
            // SAFETY: `imp` implements -setFrameOrigin:(NSPoint), a void method; PointIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: PointIMP.self)
            let block: @convention(block) (NSView, NSPoint) -> Void = { view, origin in
                guard counts(view, onMainOnly: true) else { return original(view, selector, origin) }
                let changed = MainActor.assumeIsolated { view.frame.origin != origin } // main-proof: checked in counts
                original(view, selector, origin)
                if changed { ledger.add(.frameSets, owner: Swift.type(of: view)) }
            }
            return block
        case #selector(NSView.updateLayer):
            // SAFETY: `imp` implements -updateLayer, a void method; PlainIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: PlainIMP.self)
            let block: @convention(block) (NSView) -> Void = { view in
                guard counts(view, onMainOnly: true) else { return original(view, selector) }
                original(view, selector)
                let size = MainActor.assumeIsolated { view.bounds.size } // main-proof: checked in counts
                ledger.add(.damageRects, owner: Swift.type(of: view))
                ledger.add(.damageArea, RenderStats.damageArea(width: size.width, height: size.height), owner: Swift.type(of: view))
            }
            return block
        case #selector(NSView.draw(_:)):
            // SAFETY: `imp` implements -drawRect:(NSRect), a void method; RectIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: RectIMP.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { view, dirty in
                let counted = counts(view, onMainOnly: false)
                original(view, selector, dirty)
                guard counted else { return }
                ledger.add(.damageRects, owner: Swift.type(of: view))
                ledger.add(.damageArea, RenderStats.damageArea(width: dirty.width, height: dirty.height), owner: Swift.type(of: view))
            }
            return block
        case #selector(NSView.addTrackingArea(_:)):
            // SAFETY: `imp` implements -addTrackingArea:(NSTrackingArea *), a void method; TrackingIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: TrackingIMP.self)
            let block: @convention(block) (NSView, NSTrackingArea) -> Void = { view, area in
                let counted = counts(view, onMainOnly: false)
                original(view, selector, area)
                if counted { ledger.add(.trackingAreaAdds, owner: Swift.type(of: view)) }
            }
            return block
        case #selector(setter: CALayer.contents):
            // SAFETY: `imp` implements -setContents:(id), a void method; ContentsIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: ContentsIMP.self)
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
            // SAFETY: `imp` implements -setFrame:(NSRect) display:(BOOL), a void method; WindowFrameIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: WindowFrameIMP.self)
            let block: @convention(block) (NSWindow, NSRect, ObjCBool) -> Void = { window, frame, display in
                guard counts(window, onMainOnly: true) else { return original(window, selector, frame, display) }
                let changed = MainActor.assumeIsolated { window.frame != frame } // main-proof: checked in counts
                original(window, selector, frame, display)
                if changed { ledger.add(.windowCalls, owner: Swift.type(of: window)) }
            }
            return block
        case #selector(setter: NSWindow.alphaValue):
            // SAFETY: `imp` implements -setAlphaValue:(CGFloat), a void method; AlphaIMP is its C type.
            let original = unsafe unsafeBitCast(imp, to: AlphaIMP.self)
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
