import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20: "opening and closing sidebar workspace groups still lags too much ... the algorithm must not
/// scale linearly with the number of workspaces: users will have thousands." A group's collapse is view state the
/// sidebar owns (plans/cmux-next/state-ownership-DESIGN.md): its cost is the rows it changes, never the rows it has.
///
/// The harness lists `count` workspaces in 100 groups (fewer groups below 100 workspaces), all open, in one machine
/// section, and toggles one group near the top with a real click on its header's name (mouse down and up on the
/// list, then the observation's render, as the window draws it). The toggled group always holds the same 10
/// workspaces, so 100 and 10,000 workspaces change the same rows. Each toggle's main-thread CPU is timed; the median
/// of 16 is compared.
@MainActor @Suite(.serialized) struct SidebarGroupToggleScalingTests {
    struct Harness {
        let sidebar: SidebarView
        let model: SidebarModel
        let window: NSWindow
        let target: GroupID
        var list: SidebarListView { sidebar.list }
    }

    static func make(_ count: Int) -> Harness {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (i: Int) in SidebarWorkspace(id: WorkspaceID("gt-\(i)"), title: "workspace \(i)") }
        // The toggled group has 10 members at every size.
        let fixed = 10
        let rest = max(0, count - fixed)
        let otherGroups = max(1, min(99, rest))
        var nodes: [SidebarNode] = []
        var next = 0
        func group(_ index: Int, members: Int) -> SidebarNode {
            let range = next..<(next + members)
            next += members
            return .group(SidebarGroup(id: GroupID("gt-g\(index)"), name: "Group \(index)", color: .green, workspaces: range.map(ws)))
        }
        // The toggled group is the first one, so its header is on screen at every size.
        nodes.append(group(1, members: fixed))
        let firstSize = rest / otherGroups + (rest % otherGroups > 0 ? 1 : 0)
        if rest > 0 { nodes.append(group(0, members: min(firstSize, rest))) }
        for index in stride(from: 2, through: otherGroups, by: 1) where next < count {
            let remaining = count - next, groupsLeft = otherGroups - index + 1
            nodes.append(group(index, members: max(1, remaining / groupsLeft)))
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: WorkspaceID("gt-0"))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return Harness(sidebar: sidebar, model: model, window: window, target: GroupID("gt-g1"))
    }

    struct Cost: CustomStringConvertible {
        var median: Double
        var p90: Double
        var reloadsPerToggle: Double
        var description: String { String(format: "median=%.3fms p90=%.3fms reloads/toggle=%.1f", median, p90, reloadsPerToggle) }
    }

    /// One header click's main-thread work: mouse down and up on the header's name, then the observation's render.
    static func toggle(_ h: Harness) {
        let list = h.list
        guard let header = list.rowViews[.group(h.target)] as? GroupHeaderRowView else {
            Issue.record("the toggled group's header has no view")
            return
        }
        // A plain click on the header's name (a109: any plain click on the bar folds it).
        let name = header.nameHitFrame
        let at = list.convert(header.convert(NSPoint(x: name.midX, y: name.midY), to: list), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                 windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return }
            if type == .leftMouseDown { list.mouseDown(with: event) } else { list.mouseUp(with: event) }
        }
        h.sidebar.renderNow()
    }

    /// - Parameter work: one toggle (`toggle` itself; a test stands in a toggle that waits).
    static func measure(_ h: Harness, runs: Int = 16, work: @MainActor (Harness) -> Void = { toggle($0) }) -> Cost {
        // Warm up both directions (caches, row views of the toggled rows).
        for _ in 0..<4 { toggle(h) }
        _ = SidebarPerfCounters.report(reset: true)
        // Main-thread CPU, as SidebarScrollBench times a frame: other work on the host delays the toggle, but it
        // adds nothing to the toggle's own cost.
        var samples: [Double] = []
        for _ in 0..<runs {
            let started = SidebarScrollBench.threadCPU()
            work(h)
            samples.append((SidebarScrollBench.threadCPU() - started) * 1000)
        }
        let reloads = SidebarPerfCounters.report(reset: true)["list_reloads"] ?? 0
        samples.sort()
        return Cost(median: samples[samples.count / 2], p90: samples[(samples.count * 9) / 10], reloadsPerToggle: Double(reloads) / Double(runs))
    }

    /// `measure`, with the runner's reference workload timed before and after the toggles
    /// (FrameBudgetCalibration), so a budget can be scaled to the runner they ran on.
    static func measure(_ h: Harness, runs: Int = 16, calibrating calibration: inout FrameBudgetCalibration,
                        work: @MainActor (Harness) -> Void = { toggle($0) }) -> Cost {
        calibration.checkpoint()
        let cost = measure(h, runs: runs, work: work)
        calibration.checkpoint()
        return cost
    }

    /// Where one toggle's time goes (median of 16 each, ms): the model's write, the list's splice, the render, and
    /// the mouse handling around them.
    static func phases(_ h: Harness) -> String {
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        var model: [Double] = [], list: [Double] = [], render: [Double] = [], state: [Double] = []
        let fold = h.model.onGroupFolded
        for _ in 0..<16 {
            h.model.onGroupFolded = nil
            let collapsed = h.model.group(h.target)?.isCollapsed ?? false
            model.append(ms(clock.measure { h.model.setGroupCollapsed(h.target, !collapsed) }))
            h.model.onGroupFolded = fold
            list.append(ms(clock.measure { h.list.foldGroup(h.target) }))
            render.append(ms(clock.measure { h.sidebar.renderNow() }))
            state.append(ms(clock.measure { _ = h.model.listOptions() }))
        }
        func median(_ a: [Double]) -> String { String(format: "%.3f", a.sorted()[a.count / 2]) }
        return "model=\(median(model)) list=\(median(list)) render=\(median(render)) listOptions=\(median(state))"
    }

    /// Timings at each size, printed for the design doc ("group-toggle n=..."); no budget here.
    @Test(arguments: [10, 100, 1_000, 10_000])
    func toggleTimings(_ count: Int) {
        let h = Self.make(count)
        defer { h.window.close() }
        let before = h.model.group(h.target)?.isCollapsed
        Self.toggle(h)
        #expect(h.model.group(h.target)?.isCollapsed != before, "a click on the header did not toggle the group")
        let cost = Self.measure(h)
        print("group-toggle-phases n=\(count) \(Self.phases(h))")
        print("group-toggle n=\(count) rows=\(h.list.displayed.rows.count) realized=\(h.list.rowViews.count) \(cost)")
        #expect(h.model.group(h.target) != nil)
    }

    /// The budget measures the toggle's own work, not the time its thread waits: other work on the host (another
    /// app, the next job on a shared fleet runner) delays the main thread without adding to the toggle's cost. Timed
    /// by the wall clock, a 1 ms toggle at 10,000 workspaces read 70-90 ms at p90 while threads at the highest QoS
    /// took every core (aws-m4pro-1, 2026-10-21). A toggle that waits 20 ms stands in for those delays here.
    @Test func aToggleThatWaitsCostsOnlyItsOwnWork() {
        let h = Self.make(100)
        defer { h.window.close() }
        var calibration = FrameBudgetCalibration()
        let cost = Self.measure(h, runs: 8, calibrating: &calibration) { h in
            Thread.sleep(forTimeInterval: 0.02)
            Self.toggle(h)
        }
        print("group-toggle-wait \(cost) | \(calibration.summary)")
        if let reason = calibration.skipReason { return print("group-toggle-wait skipped the 8 ms check: \(reason)") }
        #expect(cost.p90 < calibration.budget(8),
                "a toggle that waited 20 ms cost \(cost.p90) ms (p90), over 8 ms scaled to \(calibration.budget(8)) ms: the wait was counted as its work")
    }

    /// A slow runner, stood in deterministically as in SidebarScrollCostTests: every toggle and every
    /// reference sample is done `slowdown` times. This host's own reference is nominal and its own
    /// toggles set the budget, so the host's speed cancels out; the slowed toggles break that budget
    /// as it is and hold it scaled by the reference `measure` times around them.
    @Test func aToggleOnASlowRunnerIsHeldToAScaledBudget() {
        let slowdown = 3
        let h = Self.make(100)
        defer { h.window.close() }
        let fast = Self.measure(h)
        FrameBudgetCalibration.referenceWork() // warm up
        let reference = (0..<15).map { _ in FrameBudgetCalibration.cpuMs { FrameBudgetCalibration.referenceWork() } }
        var slow = FrameBudgetCalibration(nominalMs: SidebarScrollBench.percentile(reference, 0.5),
                                          reference: { for _ in 0..<slowdown { FrameBudgetCalibration.referenceWork() } })
        // An even number of toggles a run leaves the group as it found it; an odd one alternates it.
        let slowed = Self.measure(h, calibrating: &slow) { h in for _ in 0..<slowdown { Self.toggle(h) } }
        let budget = 1.5 * fast.p90
        print("group-toggle-calibration fast \(fast) slowed \(slowed) budget=\(String(format: "%.3f", budget))ms | \(slow.summary)")
        #expect(slowed.p90 > budget, "the stand-in runner is not slow enough to break an unscaled budget")
        #expect(slow.checkpoints.count == 2, "measure did not time the reference workload before and after the toggles")
        if let reason = slow.skipReason { return print("group-toggle-calibration skipped: \(reason)") }
        #expect(slowed.p90 < slow.budget(budget),
                "a runner \(slowdown)x slower at the reference took \(slowed.p90) ms a toggle against a budget scaled to \(slow.budget(budget)) ms")
    }

    /// The guard: a toggle at 10,000 workspaces costs at most 1.5x one at 100, and fits in one 8 ms frame (scaled to
    /// the runner by FrameBudgetCalibration). The ratio is not scaled: both sizes run on the same runner in one run.
    @Test func toggleCostDoesNotGrowWithWorkspaces() {
        var calibration = FrameBudgetCalibration()
        let small = Self.make(100)
        let smallCost = Self.measure(small, calibrating: &calibration)
        small.window.close()
        let large = Self.make(10_000)
        let largeCost = Self.measure(large, calibrating: &calibration)
        large.window.close()
        let ratio = largeCost.median / max(smallCost.median, 0.05)
        print("group-toggle-guard n=100 \(smallCost) n=10000 \(largeCost) ratio=\(String(format: "%.2f", ratio)) | \(calibration.summary)")
        #expect(ratio <= 1.5, "a toggle at 10,000 workspaces costs \(String(format: "%.1f", ratio))x one at 100: \(largeCost) vs \(smallCost)")
        #expect(largeCost.reloadsPerToggle <= 1, "a toggle laid the whole list out \(largeCost.reloadsPerToggle) times")
        if let reason = calibration.skipReason { return print("group-toggle-guard skipped the 8 ms check: \(reason)") }
        #expect(largeCost.p90 < calibration.budget(8),
                "a toggle at 10,000 workspaces took \(largeCost.p90) ms (p90), over one 8 ms frame scaled to \(calibration.budget(8)) ms")
    }

    /// The first fold after loading sections must not prepare every other group's lookup before the list can
    /// start moving. The warm-click harness above deliberately warms both directions and would miss that delay.
    @Test(arguments: [false, true])
    func firstFoldDoesNotScanOtherGroups(replacingSections: Bool) {
        let target = GroupID("first-fold-9999")
        func sections() -> [SidebarSection] {
            let nodes = (0..<10_000).map { index in
                SidebarNode.group(SidebarGroup(id: GroupID("first-fold-\(index)"), name: "Group \(index)", workspaces: []))
            }
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            return [SidebarSection(kind: .machine(machine), nodes: nodes)]
        }
        var first: [Double] = [], warm: [Double] = []
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        for _ in 0..<9 {
            let model = SidebarModel(sections: replacingSections ? [] : sections())
            if replacingSections { model.sections = sections() }
            // The callback is where the list starts its fold. No layout or animation work is included here.
            var reachedList = false
            model.onGroupFolded = { id in reachedList = id == target }
            first.append(FrameBudgetCalibration.cpuMs { model.setGroupCollapsed(target, true) })
            #expect(reachedList, "the first fold never reached the list")
            #expect(model.group(target)?.isCollapsed == true)
            warm.append(FrameBudgetCalibration.cpuMs { model.setGroupCollapsed(target, false) })
            model.onGroupFolded = nil
        }
        calibration.checkpoint()
        let coldMs = SidebarScrollBench.percentile(first, 0.5)
        let warmMs = SidebarScrollBench.percentile(warm, 0.5)
        print("group-first-fold replaced=\(replacingSections) n=10000 first=\(coldMs)ms warm=\(warmMs)ms | \(calibration.summary)")
        if let reason = calibration.skipReason { return print("group-first-fold skipped budget: \(reason)") }
        #expect(coldMs < max(warmMs * 1.5, calibration.budget(0.075)),
                "the first fold spent \(coldMs) ms before the list, compared with \(warmMs) ms once warm")
    }

    @Test func firstFoldFindsTheGroupAfterSectionsMoveOrRemoveIt() {
        let a = GroupID("fold-a"), b = GroupID("fold-b")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func section(_ ids: [GroupID]) -> [SidebarSection] {
            [SidebarSection(kind: .machine(machine), nodes: ids.map {
                .group(SidebarGroup(id: $0, name: $0.rawValue, workspaces: []))
            })]
        }
        let model = SidebarModel(sections: section([a, b]))
        #expect(model.group(a)?.id == a)
        model.sections = section([b, a])
        #expect(model.group(a)?.id == a)
        #expect(model.setGroupCollapsed(a, true))
        #expect(model.group(a)?.isCollapsed == true)
        #expect(model.group(b)?.isCollapsed == false)
        model.sections = section([b])
        #expect(model.group(a) == nil)
        #expect(!model.setGroupCollapsed(a, true))
        #expect(model.setGroupCollapsed(b, true))
        #expect(model.group(b)?.isCollapsed == true)
    }
}
