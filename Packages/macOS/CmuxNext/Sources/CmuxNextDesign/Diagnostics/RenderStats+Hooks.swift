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

    /// The classes that define one hooked selector themselves.
    nonisolated struct Definers: Sendable {
        let classes: Set<ObjectIdentifier>

        /// No hooked class lies between the receiver's class and `owner`: the
        /// call is the outermost hooked one (an override calling `super` counts once).
        func isOutermost(_ object: AnyObject, at owner: ObjectIdentifier) -> Bool {
            var next: AnyClass? = object_getClass(object)
            while let type = next, ObjectIdentifier(type) != owner {
                if classes.contains(ObjectIdentifier(type)) { return false }
                next = class_getSuperclass(type)
            }
            return true
        }
    }

    static let hookedSelectors: [(root: AnyClass, selectors: [Selector])] = [
        (NSView.self, [#selector(NSView.setFrameSize(_:)), #selector(NSView.setFrameOrigin(_:)), #selector(NSView.updateLayer),
                       #selector(NSView.draw(_:)), #selector(NSView.addTrackingArea(_:))]),
        (CALayer.self, [#selector(setter: CALayer.contents)]),
        (NSWindow.self, [#selector(NSWindow.setFrame(_:display:)), #selector(setter: NSWindow.alphaValue)]),
    ]

    /// Every loaded class under a root that defines a hooked selector itself,
    /// with a counting replacement that forwards to its original IMP. Reads
    /// the runtime with C calls only (no message to an unknown class).
    static func buildHooks(ledger: Ledger) -> [Hook] {
        var definers: [Selector: [(type: AnyClass, method: Method)]] = [:]
        // A lookup on the root resolves a method its class adds lazily, so the method list below has it.
        for (root, selectors) in hookedSelectors { for selector in selectors { _ = class_getInstanceMethod(root, selector) } }
        var classCount: UInt32 = 0
        guard let list = objc_copyClassList(&classCount) else { return [] }
        defer { free(UnsafeMutableRawPointer(list)) }
        for index in 0..<Int(classCount) {
            let type: AnyClass = list[index]
            guard let selectors = hookedSelectors.first(where: { isClass(type, kindOf: $0.root) })?.selectors else { continue }
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(type, &methodCount) else { continue }
            defer { free(methods) }
            for method in UnsafeBufferPointer(start: methods, count: Int(methodCount)) where selectors.contains(method_getName(method)) {
                definers[method_getName(method), default: []].append((type, method))
            }
        }
        var hooks: [Hook] = []
        for (selector, entries) in definers {
            let chain = Definers(classes: Set(entries.map { ObjectIdentifier($0.type) }))
            for entry in entries {
                let original = method_getImplementation(entry.method)
                let hook = RenderCountingHook(ledger: ledger, chain: chain, owner: ObjectIdentifier(entry.type))
                guard let block = hook.block(for: selector, calling: original) else { continue }
                hooks.append(Hook(method: entry.method, original: original, replacement: imp_implementationWithBlock(block)))
            }
        }
        return hooks
    }

    private static func isClass(_ type: AnyClass, kindOf root: AnyClass) -> Bool {
        let rootID = ObjectIdentifier(root)
        var next: AnyClass? = type
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
    let chain: RenderStats.Definers
    let owner: ObjectIdentifier

    private func counts(_ object: AnyObject, onMainOnly: Bool) -> Bool {
        ledger.isArmed && (!onMainOnly || Thread.isMainThread) && chain.isOutermost(object, at: owner)
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
