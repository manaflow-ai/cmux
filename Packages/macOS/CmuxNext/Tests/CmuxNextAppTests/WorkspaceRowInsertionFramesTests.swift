import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The insertion contract is checked on the render server's display frames rather than on
/// `SidebarListView.onApply`: the latter can miss a presentation frame. With the shipped snap
/// motion, the list applies one layout and every existing row is already at its final slot.
@MainActor @Suite(.serialized, .closesItsWindows)
struct WorkspaceRowInsertionFramesTests {
    enum Placement: String, CaseIterable, Sendable {
        case top
        case middle
        case bottom

        var ids: [Int] {
            switch self {
            case .top: [0, 1, 2, 3, 4, 5, 6]
            case .middle: [1, 2, 0, 3, 4, 5, 6]
            case .bottom: [1, 2, 3, 4, 5, 6, 0]
            }
        }

        var rowsAboveInsertion: [Int] {
            switch self {
            case .top: [-1]
            case .middle: [-1, 1, 2]
            case .bottom: [-1, 1, 2, 3, 4, 5, 6]
            }
        }
    }

    private static func sections(_ ids: [Int]) -> [SidebarSection] {
        func workspace(_ id: Int) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID(String(id)), title: "row \(id)", icon: .symbol("star", tint: nil))
        }
        let group = SidebarGroup(id: GroupID("design"), name: "Design", color: .blue, workspaces: ids.map(workspace))
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace(-1)), .group(group)])]
    }

    private static func key(_ id: Int) -> SidebarRowKey {
        .workspace(WorkspaceID(String(id)))
    }

    private static func sidebar(_ initial: [Int]) throws ->
        (model: SidebarModel, list: SidebarListView, window: NSWindow, restore: () -> Void) {
        let before = sections(initial)
        let model = SidebarModel(sections: before, activeWorkspaceID: try #require(before.first?.workspaces.first?.id))
        let list = SidebarListView(model: model)
        // Keep every row realized so a missing frame cannot be mistaken for an offscreen row.
        list.frame = NSRect(x: 0, y: 0, width: 260, height: 1_000)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 1_000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(list)
        window.orderFrontRegardless()
        list.layoutSubtreeIfNeeded()
        list.reload(animated: false)
        try #require(window.screen != nil)

        let oldReduce = Motion.reduceMotionOverride
        let oldAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        return (model, list, window, {
            Motion.reduceMotionOverride = oldReduce
            DesignSettings.shared.enabledAnimations = oldAnimations
            window.close()
        })
    }

    @Test(arguments: Placement.allCases)
    func everyDisplayFrameKeepsExistingRowsVisibleAndAtTheirFinalSlot(_ placement: Placement) throws {
        let initial = [1, 2, 3, 4, 5, 6]
        let (model, list, _, restore) = try Self.sidebar(initial)
        defer { restore() }
        try #require(SidebarInsertMotion.tunable.value == .snap,
                     "the default insertion motion must snap existing rows")

        let baseline = list.rowViews
        let baselineKeys = baseline.keys.map(String.init(describing:))
        let baselineFrames = Dictionary(uniqueKeysWithValues: baseline.map { (String(describing: $0.key), $0.value.frame) })
        try #require(baseline.count >= initial.count + 2, "all existing workspace and group rows must be realized")

        var applyCount = 0
        list.onApply = { _ in applyCount += 1 }
        list.motionProbe.start()
        model.noteUserIntent()
        model.sections = Self.sections(placement.ids)
        list.reload(animated: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        let frames = list.motionProbe.stop()
        list.onApply = nil
        #expect(applyCount == 1, "insertion used \(applyCount) layout passes")
        try #require(frames.count >= 2, "the real display link produced no insertion frames")

        let targets = Dictionary(uniqueKeysWithValues: baseline.keys.compactMap { key in
            list.displayed.row(for: key).map { (String(describing: key), list.frame(for: $0)) }
        })
        let insertedKey = String(describing: Self.key(0))
        let insertedRow = try #require(list.displayed.row(for: Self.key(0)))
        let insertedFrame = list.frame(for: insertedRow)
        try #require(Set(targets.keys) == Set(baselineKeys), "all baseline rows must have final slots")

        for (index, frame) in frames.enumerated() {
            let inserted = try #require(frame.views[insertedKey], "frame \(index) omitted the inserted row")
            #expect(abs(inserted.minY - insertedFrame.minY) < 0.5,
                    "frame \(index) drew the new row outside its final slot")
            for key in baselineKeys {
                let shown = try #require(frame.views[key], "frame \(index) omitted existing row \(key)")
                let opacity = try #require(frame.opacity[key], "frame \(index) omitted opacity for \(key)")
                #expect(opacity > 0.99, "frame \(index) hid existing row \(key)")
                let target = try #require(targets[key])
                #expect(abs(shown.minY - target.minY) < 0.5 && abs(shown.maxY - target.maxY) < 0.5,
                        "frame \(index) moved \(key) away from its final slot: \(shown) vs \(target)")
            }

            // Rows above a middle insertion retain their exact pre-insert positions.
            for id in placement.rowsAboveInsertion {
                let key = String(describing: Self.key(id))
                let shown = try #require(frame.views[key])
                let before = try #require(baselineFrames[key])
                #expect(abs(shown.minY - before.minY) < 0.5,
                        "frame \(index) moved row above the insertion: \(key)")
            }
        }
    }
}
