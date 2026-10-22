import AppKit
@testable import CmuxNextApps
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import QuartzCore
import SwiftUI
import Testing

/// The custom sidebar's main-thread budget (plans/cmux-next/custom-sidebar-DESIGN.md): with a
/// script on, one input change at 500 workspaces costs p95 < 1 ms on the main thread, from the
/// op batch landing to the hosting view laid out and drawn. The script itself runs in the app
/// host process, so the batch is all the app sees. The native list is measured the same way as
/// the "no script" row of the table.
@MainActor
@Suite(.serialized) struct CustomSidebarPerfTests {
    static let workspaces = 500
    static let samples = 200
    static let budgetMs = 1.0

    /// What a typical custom sidebar mounts per workspace: an unread dot, a title, a spacer and a
    /// status text in an HStack (four nodes a row, 2000 in all), in a keyed ForEach in a LazyVStack.
    static func scene(_ count: Int) -> AppSceneModel {
        let model = AppSceneModel()
        var ops: [AppSceneOp] = [.create(id: "list", type: "LazyVStack", props: ["spacing": .number(2)]),
                                 .create(id: "each", type: "ForEach", props: [:])]
        for index in 0..<count {
            ops += [
                .create(id: "w\(index)", type: "HStack", props: ["spacing": .number(6), "padding": .number(4)]),
                .create(id: "w\(index).dot", type: "Circle", props: ["fill": .string("accent"), "frame": .object(["width": .number(6), "height": .number(6)])]),
                .create(id: "w\(index).title", type: "Text", props: ["text": .string("workspace \(index)"), "lineLimit": .number(1)]),
                .create(id: "w\(index).gap", type: "Spacer", props: [:]),
                .create(id: "w\(index).status", type: "Text", props: ["text": .string("idle"), "color": .string("secondary")]),
                .children(id: "w\(index)", children: ["w\(index).dot", "w\(index).title", "w\(index).gap", "w\(index).status"]),
            ]
        }
        ops += [.children(id: "each", children: (0..<count).map { "w\($0)" }), .children(id: "list", children: ["each"]), .root(id: "list")]
        model.apply(ops)
        return model
    }

    static func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return window
    }

    /// Milliseconds per `change(i)` plus the layout and drawing it causes, after `warmup` runs.
    static func measure(_ view: NSView, warmup: Int = 20, calibrating calibration: inout FrameBudgetCalibration,
                        _ change: (Int) -> Void) -> [Double] {
        var out: [Double] = []
        calibration.checkpoint()
        for index in 0..<(warmup + samples) {
            if index == warmup + samples / 2 { calibration.checkpoint() }
            let start = CACurrentMediaTime()
            change(index)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            CATransaction.flush()
            let elapsed = (CACurrentMediaTime() - start) * 1000
            if index >= warmup { out.append(elapsed) }
        }
        calibration.checkpoint()
        return out
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    static func report(_ name: String, _ values: [Double]) -> (p50: Double, p95: Double) {
        let p50 = percentile(values, 0.5), p95 = percentile(values, 0.95)
        print(String(format: "CUSTOM_SIDEBAR_PERF %@ workspaces=%d samples=%d p50_ms=%.3f p95_ms=%.3f max_ms=%.3f",
                     name, workspaces, values.count, p50, p95, values.max() ?? 0))
        return (p50, p95)
    }

    /// Updates alternate between a row on screen (it must redraw) and one far below (it must cost nothing).
    static func row(_ index: Int) -> Int { index.isMultiple(of: 2) ? (index * 7) % 30 : 300 + (index * 13) % 200 }

    @Test func aOneRowUpdateWithAScriptStaysUnderTheBudget() {
        let model = Self.scene(Self.workspaces)
        let hosting = NSHostingView(rootView: ScrollView { AppSceneView(model: model) })
        let window = Self.host(hosting)
        defer { window.contentView = nil; window.close() }
        var calibration = FrameBudgetCalibration()
        let times = Self.measure(hosting, calibrating: &calibration) { index in
            let row = Self.row(index)
            model.apply([.update(id: "w\(row).status", props: ["text": .string(index.isMultiple(of: 3) ? "working" : "idle \(index)")])])
        }
        let (_, p95) = Self.report("script", times)
        // Main-thread CPU differs 3-4x between fleet runners and under parallel suites
        // (FrameBudgetCalibration): the 1 ms budget is scaled to this runner, never tightened.
        print("CUSTOM_SIDEBAR_PERF \(calibration.summary)")
        if let reason = calibration.skipReason { return print("CUSTOM_SIDEBAR_PERF skipped the 1 ms check: \(reason)") }
        #expect(p95 < calibration.budget(Self.budgetMs),
                "p95 \(p95) ms at \(Self.workspaces) workspaces, over 1 ms scaled to \(calibration.budget(Self.budgetMs)) ms")
    }

    /// The native list, no script: the baseline the custom sidebar is compared with.
    @Test func aOneRowUpdateWithoutAScript() {
        let rows = (0..<Self.workspaces).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)", kind: .terminal) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })], activeWorkspaceID: nil)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = Self.host(sidebar)
        defer { window.contentView = nil; window.close() }
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        var calibration = FrameBudgetCalibration()
        let times = Self.measure(sidebar, calibrating: &calibration) { index in
            var row = rows[Self.row(index)]
            row.unread = index.isMultiple(of: 3) ? .dot : .none
            row.title = "workspace \(index)"
            _ = model.patchWorkspaces([row])
        }
        _ = Self.report("native", times)
        print("CUSTOM_SIDEBAR_PERF native \(calibration.summary)")
    }
}
