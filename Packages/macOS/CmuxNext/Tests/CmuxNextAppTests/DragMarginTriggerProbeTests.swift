import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Foundation
import ObjectiveC
import QuartzCore
import Testing

/// HOT PATH AUDIT frames, measurement only (no product change): what makes AppKit rebuild the window's drag margins
/// on a layout motion frame. A STRESS divider drag spends 129 of 996 busy main-thread ms in
/// `-[NSWindow _resetDragMarginsIfNeeded]` -> `_getConstrainedWindowMinSize` -> a walk of every view
/// (`_willMeasureMinSizeForFullscreen`), job 02225774068545169e3b1901. The sampler shows the cost, not who asked for
/// it. This probe lists NSWindow's private drag-margin and structural-region methods at run time, counts their calls
/// per motion frame (a pane spring in a `ShellWindow` wired as the app wires it, `LayoutWorkProbe`), and prints the
/// call stack of the first call of each method whose name says it marks the margins dirty. Prints `HPA-MARGIN` lines.
@MainActor @Suite(.serialized, .closesItsWindows)
struct DragMarginTriggerProbeTests {
    @Test func whatInvalidatesTheDragMarginsPerMotionFrame() async throws {
        let names = MarginSpy.install()
        print("HPA-MARGIN methods \(names.sorted().joined(separator: ","))")
        try #require(!names.isEmpty, "NSWindow lists no drag-margin method on this macOS")
        defer { MarginSpy.uninstall() }
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        probe.window.orderFront(nil)
        flush(probe.window)
        var next = columns
        next[1] = PaneMotionBench.column(1, rows: 2, width: 0.25)
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        for _ in 0..<4 { await Task.yield() }
        MarginSpy.reset()
        var frames = 0
        while frames < 120, probe.root.advanceFrame(1.0 / 120) {
            frames += 1
            flush(probe.window)
        }
        let views = countViews(probe.window.contentView)
        print("HPA-MARGIN frames=\(frames) window_views=\(views) constraints_in_content=\(countConstraints(probe.window.contentView))")
        for (name, count) in MarginSpy.counts.sorted(by: { $0.key < $1.key }) {
            print("HPA-MARGIN calls \(name)=\(count) per_frame=\(String(format: "%.2f", Double(count) / Double(max(frames, 1))))")
        }
        for (name, stack) in MarginSpy.firstStacks.sorted(by: { $0.key < $1.key }) {
            print("HPA-MARGIN stack \(name):")
            for line in stack.prefix(24) { print("HPA-MARGIN   \(line)") }
        }
    }

    /// What one display cycle does after the frame's changes: layout, display and the CA commit with AppKit's
    /// display-cycle observers (where `_resetDragMarginsIfNeeded` runs).
    private func flush(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }

    private func countViews(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        return 1 + view.subviews.reduce(0) { $0 + countViews($1) }
    }

    private func countConstraints(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        return view.constraints.count + view.subviews.reduce(0) { $0 + countConstraints($1) }
    }
}

/// Counts calls of NSWindow's private drag-margin methods by swizzling them with a counting block (test only).
@MainActor
enum MarginSpy {
    static var counts: [String: Int] = [:]
    static var firstStacks: [String: [String]] = [:]
    private static var originals: [(Method, IMP)] = []

    static func reset() {
        counts = [:]
        firstStacks = [:]
    }

    /// Swizzles every NSWindow method whose name mentions drag margins, structural regions or the constrained min
    /// size, and that takes no argument or one object/bool argument (the shapes a counting block can stand in for).
    static func install() -> [String] {
        var installed: [String] = []
        var count: UInt32 = 0
        guard let list = class_copyMethodList(NSWindow.self, &count) else { return [] }
        defer { free(list) }
        for index in 0..<Int(count) {
            let method = list[index]
            let name = NSStringFromSelector(method_getName(method))
            let lower = name.lowercased()
            guard lower.contains("dragmargin") || lower.contains("structuralregion") || lower.contains("constrainedwindowminsize")
                    || lower.contains("regionforopaqueviews") else { continue }
            guard let types = method_getTypeEncoding(method).map({ String(cString: $0) }) else { continue }
            let original = method_getImplementation(method)
            let selector = method_getName(method)
            // Only `v@:` (no argument) and `v@:B` / `v@:c` (one bool) are wrapped; others are listed, not wrapped.
            if types.hasPrefix("v16@0:8") || types == "v@:" {
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let call = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject) -> Void = { this in
                    MainActor.assumeIsolated { note(name) } // main-proof: AppKit calls window region methods on main
                    call(this, selector)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                originals.append((method, original))
                installed.append(name)
            } else if types.hasPrefix("v20@0:8B16") || types.hasPrefix("v20@0:8c16") {
                typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
                let call = unsafeBitCast(original, to: Fn.self)
                let block: @convention(block) (AnyObject, Bool) -> Void = { this, flag in
                    MainActor.assumeIsolated { note(name) } // main-proof: AppKit calls window region methods on main
                    call(this, selector, flag)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                originals.append((method, original))
                installed.append(name)
            } else {
                installed.append("\(name)[\(types),not-wrapped]")
            }
        }
        return installed
    }

    static func uninstall() {
        for (method, original) in originals { method_setImplementation(method, original) }
        originals = []
    }

    private static func note(_ name: String) {
        counts[name, default: 0] += 1
        let lower = name.lowercased()
        if firstStacks[name] == nil, lower.contains("set") || lower.contains("invalidate") || lower.contains("needs") {
            firstStacks[name] = Thread.callStackSymbols.map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
            }
        }
    }
}
