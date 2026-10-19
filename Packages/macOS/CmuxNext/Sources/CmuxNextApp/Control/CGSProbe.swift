import AppKit
import CmuxNextControl
import ObjectiveC

/// PROBE ONLY (perf-polish cx-8w027.28, never landed): between `debug.frames` start and stop,
/// with CMUX_NEXT_PROBE_CGS=1, counts the callers of `+[_NSCGSTransaction currentTransaction]`
/// (who opens a window-server transaction inside a commit) and of AppKit's structural-region,
/// drag-margin, cursor-rect and shadow methods (who marks window-server state dirty).
nonisolated enum CGSProbe {
    // crash-allow: probe only; main thread only.
    nonisolated(unsafe) static var recording = false
    // crash-allow: probe only; main thread only.
    nonisolated(unsafe) static var stacks: [String: Int] = [:]
    // crash-allow: probe only; main thread only.
    nonisolated(unsafe) static var calls: [String: Int] = [:]
    // crash-allow: probe only; main thread only.
    nonisolated(unsafe) static var hooked: [String] = []
    // crash-allow: probe only; main thread only.
    nonisolated(unsafe) static var seen: [String] = []
    // crash-allow: probe only; main thread only.
    nonisolated(unsafe) private static var installed = false

    static let patterns = ["Structural", "DragMargin", "DragShape", "ursorRect", "nvalidateShadow", "ShadowIfNeeded",
                           "ShapeIfNeeded", "_setTitlebar", "TrackingArea"]

    static func record(_ name: String) {
        guard Thread.isMainThread, recording else { return }
        calls[name, default: 0] += 1
        guard (calls[name] ?? 0) <= 60, stacks.count < 400 else { return }
        let key = Thread.callStackSymbols.dropFirst(2).prefix(30).map {
            $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
        }.joined(separator: " | ")
        stacks[name + " <= " + key, default: 0] += 1
    }

    static func install() {
        guard !installed, ProcessInfo.processInfo.environment["CMUX_NEXT_PROBE_CGS"] == "1" else { return }
        installed = true
        if let cls = NSClassFromString("_NSCGSTransaction"), // crash-allow: probe only
           let method = class_getClassMethod(cls, NSSelectorFromString("currentTransaction")) { // crash-allow: probe only
            hook(method, name: "+currentTransaction", returnsObject: true)
        }
        var done = Set<OpaquePointer>()
        for name in ["NSWindow", "NSView", "NSThemeFrame", "NSTitlebarView", "NSTitlebarContainerView", "NSNextStepFrame"] {
            guard let cls = NSClassFromString(name) else { continue } // crash-allow: probe only
            var count: UInt32 = 0
            guard let list = class_copyMethodList(cls, &count) else { continue }
            defer { free(list) }
            for i in 0..<Int(count) {
                let method = list[i]
                let selector = NSStringFromSelector(method_getName(method))
                guard patterns.contains(where: { selector.contains($0) }) else { continue }
                let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
                seen.append("\(name) \(selector) \(encoding)")
                guard !done.contains(method) else { continue }
                let plain = encoding.replacingOccurrences(of: #"[0-9]"#, with: "", options: .regularExpression)
                if plain == "v@:" {
                    done.insert(method)
                    hook(method, name: "-[\(name) \(selector)]", returnsObject: false)
                } else if plain == "v@:@" {
                    done.insert(method)
                    hookObject(method, name: "-[\(name) \(selector)]")
                }
            }
        }
    }

    private static func hook(_ method: Method, name: String, returnsObject: Bool) {
        let original = method_getImplementation(method)
        let selector = method_getName(method)
        hooked.append(name)
        if returnsObject {
            typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
            let block: @convention(block) (AnyObject) -> AnyObject? = { me in
                record(name)
                return unsafeBitCast(original, to: Fn.self)(me, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let block: @convention(block) (AnyObject) -> Void = { me in
                record(name)
                unsafeBitCast(original, to: Fn.self)(me, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    private static func hookObject(_ method: Method, name: String) {
        let original = method_getImplementation(method)
        let selector = method_getName(method)
        hooked.append(name)
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { me, arg in
            record(name)
            unsafeBitCast(original, to: Fn.self)(me, selector, arg)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static func start() {
        install()
        stacks = [:]
        calls = [:]
        recording = true
    }

    static func stop() { recording = false }

    static var json: JSONValue {
        let value: [String: JSONValue] = ["calls": .array(calls.sorted { $0.value > $1.value }.map { JSONValue.string("\($0.value)x \($0.key)") }),
         "hooked": .array(hooked.map { JSONValue.string($0) }),
         "seen": .array(seen.map { JSONValue.string($0) }),
         "stacks": .array(stacks.sorted { $0.value > $1.value }.map { JSONValue.string("\($0.value)x \($0.key)") })]
        return .object(value)
    }
}
