import AppKit
import CmuxNextSettings
import ObjectiveC

/// PROBE ONLY (perf-drag cx-8w027.19, never landed): with CMUX_NEXT_PROBE_DRAGMARGINS=1, counts
/// AppKit's titlebar drag-shape resets (`-[NSWindow _resetDragMargins]`) between `debug.frames`
/// start and stop, and records the callers that mark them needed
/// (`_setNeedsToResetDragMargins:` YES) and that mark structural regions dirty.
/// CMUX_NEXT_PROBE_NODRAGMARGINS=1 makes `_resetDragMarginsIfNeeded` a no-op (A/B).
enum DragMarginProbe {
    nonisolated(unsafe) static var recording = false // crash-allow: probe only, never landed
    nonisolated(unsafe) static var resets = 0 // crash-allow: probe only, never landed
    nonisolated(unsafe) static var needs = 0 // crash-allow: probe only, never landed
    nonisolated(unsafe) static var structural = 0 // crash-allow: probe only, never landed
    nonisolated(unsafe) static var needStacks: [String: Int] = [:] // crash-allow: probe only, never landed
    nonisolated(unsafe) static var structuralStacks: [String: Int] = [:]
    nonisolated(unsafe) static var movableFlags: [String: Int] = [:] // crash-allow: probe only, never landed // crash-allow: probe only, never landed
    nonisolated(unsafe) private static var installed = false // crash-allow: probe only, never landed
    nonisolated(unsafe) private static var originalNeeds: IMP? // crash-allow: probe only, never landed
    nonisolated(unsafe) private static var originalReset: IMP? // crash-allow: probe only, never landed
    nonisolated(unsafe) private static var originalStructural: IMP? // crash-allow: probe only, never landed

    static func reset() {
        resets = 0; needs = 0; structural = 0; needStacks = [:]; structuralStacks = [:]; movableFlags = [:]
    }

    private static func stackKey() -> String {
        Thread.callStackSymbols.dropFirst(2).prefix(30).map {
            $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
        }.joined(separator: " | ")
    }

    static func install() {
        let env = ProcessInfo.processInfo.environment
        guard !installed else { return }
        installed = true
        if env["CMUX_NEXT_PROBE_NODRAGMARGINS"] == "1",
           let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_resetDragMarginsIfNeeded")) { // crash-allow: probe only, never landed
            let block: @convention(block) (AnyObject) -> Void = { _ in }
            method_setImplementation(method, imp_implementationWithBlock(block)) // crash-allow: probe only, never landed
        }
        guard env["CMUX_NEXT_PROBE_DRAGMARGINS"] == "1" else { return }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_setNeedsToResetDragMargins:")) { // crash-allow: probe only, never landed
            originalNeeds = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            let block: @convention(block) (AnyObject, Bool) -> Void = { me, flag in
                if flag, Thread.isMainThread {
                    if recording {
                        needs += 1
                        if let window = me as? NSWindow {
                            movableFlags["movableByBackground=\(window.isMovableByWindowBackground) movable=\(window.isMovable) transparent=\(window.titlebarAppearsTransparent)", default: 0] += 1
                        }
                        if needs <= 40 { needStacks[stackKey(), default: 0] += 1 }
                    }
                }
                guard let original = originalNeeds else { return } // crash-allow: probe only
                unsafeBitCast(original, to: Fn.self)(me, NSSelectorFromString("_setNeedsToResetDragMargins:"), flag) // crash-allow: probe only, never landed
            }
            method_setImplementation(method, imp_implementationWithBlock(block)) // crash-allow: probe only, never landed
        }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_resetDragMargins")) { // crash-allow: probe only, never landed
            originalReset = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let block: @convention(block) (AnyObject) -> Void = { me in
                if Thread.isMainThread, recording { resets += 1 } // crash-allow: probe only, never landed
                guard let original = originalReset else { return } // crash-allow: probe only
                unsafeBitCast(original, to: Fn.self)(me, NSSelectorFromString("_resetDragMargins")) // crash-allow: probe only, never landed
            }
            method_setImplementation(method, imp_implementationWithBlock(block)) // crash-allow: probe only, never landed
        }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_updateStructuralRegionsOnNextDisplayCycle")) { // crash-allow: probe only, never landed
            originalStructural = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let block: @convention(block) (AnyObject) -> Void = { me in
                if Thread.isMainThread {
                    if recording {
                        structural += 1
                        if structural <= 40 { structuralStacks[stackKey(), default: 0] += 1 }
                    }
                }
                guard let original = originalStructural else { return } // crash-allow: probe only
                unsafeBitCast(original, to: Fn.self)(me, NSSelectorFromString("_updateStructuralRegionsOnNextDisplayCycle")) // crash-allow: probe only, never landed
            }
            method_setImplementation(method, imp_implementationWithBlock(block)) // crash-allow: probe only, never landed
        }
    }

    @MainActor static var json: JSONValue {
        ["flags": .array(movableFlags.map { .string("\($0.value)x \($0.key)") }), "resets": JSONValue(resets), "needs": JSONValue(needs), "structural": JSONValue(structural),
         "need_stacks": .array(needStacks.sorted { $0.value > $1.value }.prefix(40).map { .string("\($0.value)x \($0.key)") }),
         "structural_stacks": .array(structuralStacks.sorted { $0.value > $1.value }.prefix(40).map { .string("\($0.value)x \($0.key)") })]
    }
}
