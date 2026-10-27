#if DEBUG || CMUX_BENCH_HOOKS
internal import AppKit
internal import Darwin
internal import ObjectiveC

private typealias HitTestIMP = @convention(c) (NSView, Selector, NSPoint) -> NSView?

extension HitTestAudit {
    /// One class's own `hitTest:` method: its ``classKey(_:)`` and its `Method`'s address.
    nonisolated struct Definer: Sendable, Equatable {
        let key: UInt
        let method: UInt
    }

    /// One replaced method, as raw pointers (a `Method` and its IMPs stay valid for the process's life).
    nonisolated struct HookEntry: Sendable, Equatable {
        let method: UInt
        let original: UInt
        let replacement: UInt
    }

    /// One hook per definer: the kept one when its method still runs the IMP it replaced (or its replacement), else
    /// a new one over the method's IMP now.
    func makeHooks(for definers: [Definer]) -> [HookEntry] {
        let kept = Dictionary(hooks.map { ($0.method, $0) }, uniquingKeysWith: { first, _ in first })
        let root = Self.classKey(NSView.self)
        var made: [HookEntry] = []
        made.reserveCapacity(definers.count)
        for definer in definers {
            guard let method = Method(bitPattern: definer.method) else { continue }
            let current = unsafeBitCast(method_getImplementation(method), to: UInt.self)
            if let hook = kept[definer.method], current == hook.original || current == hook.replacement {
                made.append(hook)
                continue
            }
            let row: Int? = definer.key == root
                ? nil
                : recorder.row(key: definer.key, type: unsafeBitCast(definer.key, to: AnyClass.self), definesHitTest: true)
            let block = HitTestAuditHook(recorder: recorder, row: row).block(calling: method_getImplementation(method))
            let replacement = unsafeBitCast(imp_implementationWithBlock(block), to: UInt.self)
            made.append(HookEntry(method: definer.method, original: current, replacement: replacement))
        }
        return made
    }

    /// Sets each method to its replacement where it runs its original (`installing`), or back to its original
    /// where it still runs the replacement (a swizzler that chained onto a hook keeps it; the hook then passes
    /// through, since the recorder stopped). Off the main thread: each set flushes method caches.
    @concurrent
    nonisolated static func swap(_ hooks: [HookEntry], installing: Bool) async {
        for (index, hook) in hooks.enumerated() {
            if index % 256 == 255 { await Task.yield() }
            guard let method = Method(bitPattern: hook.method) else { continue }
            let current = unsafeBitCast(method_getImplementation(method), to: UInt.self)
            let (expected, target) = installing ? (hook.original, hook.replacement) : (hook.replacement, hook.original)
            if current == expected { method_setImplementation(method, unsafeBitCast(target, to: IMP.self)) }
        }
    }

    /// How many classes the runtime has loaded. Off the main thread: it takes the runtime lock.
    @concurrent
    nonisolated static func loadedClassCount() async -> Int32 {
        objc_getClassList(nil, 0)
    }

    /// The `hitTest:` methods defined by `NSView` and by each loaded subclass itself, or by the given classes only
    /// (by ``classKey(_:)``).
    /// Off the main thread. It reads the class list as raw pointers and sends no message (a retain included) to a
    /// class: a root class without `retain` (JSExport) aborts on one.
    @concurrent
    nonisolated static func scanDefiners(onlyClassKeys: [UInt]?) async -> [Definer] {
        let selector = #selector(NSView.hitTest(_:))
        // A lookup resolves a method NSView adds lazily, so its method list has it.
        _ = class_getInstanceMethod(NSView.self, selector)
        if let onlyClassKeys { return onlyClassKeys.flatMap { ownMethods(of: $0, selector: selector) } }
        let root = classKey(NSView.self)
        var listCount: UInt32 = 0
        guard let list = objc_copyClassList(&listCount) else { return [] }
        let raw = UnsafeMutableRawPointer(list)
        defer { free(raw) }
        // The list holds Objective-C class objects: each entry's bits are its ``classKey(_:)``.
        let classes = raw.assumingMemoryBound(to: UInt.self)
        var underView: [UInt: Bool] = [root: true]
        var found: [Definer] = []
        for position in 0..<Int(listCount) {
            if position % 1_024 == 1_023 { await Task.yield() }
            let key = classes[position]
            guard descends(key, memo: &underView) else { continue }
            found += ownMethods(of: key, selector: selector)
        }
        return found
    }

    /// Whether the class at `key` is `NSView` or under it, by superclass pointers only (`memo` holds the answer per
    /// ``classKey(_:)`` already walked; it starts with NSView's).
    nonisolated static func descends(_ key: UInt, memo: inout [UInt: Bool]) -> Bool {
        var walked: [UInt] = []
        var next: UInt? = key
        var result = false
        while let current = next {
            if let known = memo[current] {
                result = known
                break
            }
            walked.append(current)
            next = class_getSuperclass(unsafeBitCast(current, to: AnyClass.self)).map { classKey($0) }
        }
        for walkedKey in walked { memo[walkedKey] = result }
        return result
    }

    /// The class's own `selector` method, if it defines one.
    nonisolated static func ownMethods(of key: UInt, selector: Selector) -> [Definer] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(unsafeBitCast(key, to: AnyClass.self), &count) else { return [] }
        defer { free(methods) }
        return UnsafeBufferPointer(start: methods, count: Int(count))
            .filter { method_getName($0) == selector }
            .map { Definer(key: key, method: UInt(bitPattern: $0)) }
    }
}

/// The recording replacement of one `hitTest:` IMP. Nonisolated so its block carries no isolation check: a call off
/// the main thread runs the original unrecorded instead of trapping.
nonisolated struct HitTestAuditHook {
    let recorder: HitTestAuditRecorder
    /// The override's row; nil for NSView's own IMP, whose row is the receiver's class.
    let row: Int?

    func block(calling imp: IMP) -> Any {
        let original = unsafeBitCast(imp, to: HitTestIMP.self)
        let selector = #selector(NSView.hitTest(_:))
        let recorder = recorder
        let row = row
        let block: @convention(block) (NSView, NSPoint) -> NSView? = { view, point in
            guard Thread.isMainThread else { return original(view, selector, point) }
            let receiver = UInt(bitPattern: ObjectIdentifier(view))
            let entered = MainActor.assumeIsolated { // main-proof: Thread.isMainThread checked above
                recorder.enter(receiver: receiver) { row ?? recorder.inheritedRow(of: object_getClass(view)) }
            }
            let hit = original(view, selector, point)
            if entered {
                MainActor.assumeIsolated { recorder.exit() } // main-proof: Thread.isMainThread checked above
            }
            return hit
        }
        return block
    }
}
#endif
