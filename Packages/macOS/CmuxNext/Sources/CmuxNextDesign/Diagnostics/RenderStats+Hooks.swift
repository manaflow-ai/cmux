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
            _ = class_getInstanceMethod(method.root, method.selector)
        }
        var definers = [[Definer]](repeating: [], count: methods.count)
        var listCount: UInt32 = 0
        guard let list = objc_copyClassList(&listCount) else { return ClassScan(classCount: classCount, definers: definers) }
        let raw = UnsafeMutableRawPointer(list)
        defer { free(raw) }
        let classes = raw.assumingMemoryBound(to: UnsafeRawPointer.self)
        for position in 0..<Int(listCount) {
            if position % 1_024 == 1_023 { await Task.yield() }
            let key = UInt(bitPattern: classes[position])
            let type = unsafeBitCast(classes[position], to: AnyClass.self)
            let root = roots.indexes[key] != nil ? key : roots.root(above: type)
            guard let hooked = roots.indexes[root] else { continue }
            var methodCount: UInt32 = 0
            guard let methodList = class_copyMethodList(type, &methodCount) else { continue }
            defer { free(methodList) }
            for method in UnsafeBufferPointer(start: methodList, count: Int(methodCount)) {
                let name = method_getName(method)
                for slot in hooked where methods[slot].selector == name && (key != root || methods[slot].onRoot) {
                    definers[slot].append(Definer(key: key, method: UInt(bitPattern: method)))
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
        let entries: [[(key: UInt, method: Method)]] = scan.definers.map { definers in
            definers.compactMap { definer in Method(bitPattern: definer.method).map { (definer.key, $0) } }
        }
        let wanted = Set(entries.joined().map { $0.method })
        if !hooks.hooks.isEmpty, Set(hooks.hooks.map(\.method)) == wanted,
           hooks.hooks.allSatisfy({ method_getImplementation($0.method) == $0.original }) {
            return hooks
        }
        var set = HookSet(generation: hooks.generation + 1)
        for (index, list) in entries.enumerated() where index < methods.count {
            let chain = Definers(classes: Set(list.map { $0.key }))
            for entry in list {
                let original = method_getImplementation(entry.method)
                let hook = RenderCountingHook(ledger: ledger, generation: set.generation, chain: chain, owner: entry.key)
                guard let block = hook.block(for: methods[index].selector, calling: original) else { continue }
                set.hooks.append(Hook(method: entry.method, original: original, replacement: imp_implementationWithBlock(block)))
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
                ledger.add(.damageArea, RenderStats.damageArea(width: size.width, height: size.height), owner: Swift.type(of: view))
            }
            return block
        case #selector(NSView.draw(_:)):
            let original = unsafeBitCast(imp, to: RectIMP.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { view, dirty in
                let counted = counts(view, onMainOnly: false)
                original(view, selector, dirty)
                guard counted else { return }
                ledger.add(.damageRects, owner: Swift.type(of: view))
                ledger.add(.damageArea, RenderStats.damageArea(width: dirty.width, height: dirty.height), owner: Swift.type(of: view))
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
