import AppKit
import CmuxNextControl
import ObjectiveC

/// PROBE ONLY (perf-drag cx-8w027.19, never landed): with CMUX_NEXT_PROBE_DRAGMARGINS=1, counts
/// AppKit's titlebar drag-shape resets (`-[NSWindow _resetDragMargins]`) between `debug.frames`
/// start and stop, and records the callers that mark them needed
/// (`_setNeedsToResetDragMargins:` YES) and that mark structural regions dirty.
/// CMUX_NEXT_PROBE_NODRAGMARGINS=1 makes `_resetDragMarginsIfNeeded` a no-op (A/B).
@MainActor
enum DragMarginProbe {
    static var recording = false
    static var resets = 0
    static var needs = 0
    static var structural = 0
    static var needStacks: [String: Int] = [:]
    static var structuralStacks: [String: Int] = [:]
    private static var installed = false
    nonisolated(unsafe) private static var originalNeeds: IMP?
    nonisolated(unsafe) private static var originalReset: IMP?
    nonisolated(unsafe) private static var originalStructural: IMP?

    static func reset() {
        resets = 0; needs = 0; structural = 0; needStacks = [:]; structuralStacks = [:]
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
           let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_resetDragMarginsIfNeeded")) {
            let block: @convention(block) (AnyObject) -> Void = { _ in }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        guard env["CMUX_NEXT_PROBE_DRAGMARGINS"] == "1" else { return }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_setNeedsToResetDragMargins:")) {
            originalNeeds = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            let block: @convention(block) (AnyObject, Bool) -> Void = { me, flag in
                if flag, Thread.isMainThread {
                    MainActor.assumeIsolated {
                        if recording {
                            needs += 1
                            if needStacks.count < 300 { needStacks[stackKey(), default: 0] += 1 }
                        }
                    }
                }
                unsafeBitCast(originalNeeds!, to: Fn.self)(me, NSSelectorFromString("_setNeedsToResetDragMargins:"), flag)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_resetDragMargins")) {
            originalReset = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let block: @convention(block) (AnyObject) -> Void = { me in
                if Thread.isMainThread { MainActor.assumeIsolated { if recording { resets += 1 } } }
                unsafeBitCast(originalReset!, to: Fn.self)(me, NSSelectorFromString("_resetDragMargins"))
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_updateStructuralRegionsOnNextDisplayCycle")) {
            originalStructural = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector) -> Void
            let block: @convention(block) (AnyObject) -> Void = { me in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        if recording {
                            structural += 1
                            if structuralStacks.count < 300 { structuralStacks[stackKey(), default: 0] += 1 }
                        }
                    }
                }
                unsafeBitCast(originalStructural!, to: Fn.self)(me, NSSelectorFromString("_updateStructuralRegionsOnNextDisplayCycle"))
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    static var json: JSONValue {
        ["resets": JSONValue(resets), "needs": JSONValue(needs), "structural": JSONValue(structural),
         "need_stacks": .array(needStacks.sorted { $0.value > $1.value }.prefix(40).map { .string("\($0.value)x \($0.key)") }),
         "structural_stacks": .array(structuralStacks.sorted { $0.value > $1.value }.prefix(40).map { .string("\($0.value)x \($0.key)") })]
    }
}
