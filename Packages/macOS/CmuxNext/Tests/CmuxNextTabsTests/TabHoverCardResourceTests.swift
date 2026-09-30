import AppKit
import CmuxNextResources
import Testing
@testable import CmuxNextTabs

@MainActor
private final class RecordingSource: ResourceSampleSource {
    var targets: [ResourceTarget] = []
    func sample(_ target: ResourceTarget) async -> ResourceSampleSet {
        targets.append(target)
        return .empty
    }
}

/// The tab hover card samples CPU and memory only while a card is pending
/// or shown: from hover start until it hides.
@MainActor
@Suite struct TabHoverCardResourceTests {
    @Test func samplingStartsAtHoverStartAndStopsWhenTheCardHides() async {
        let source = RecordingSource()
        let controller = TabHoverCardController()
        controller.resources.setSource(source)
        #expect(!controller.resources.isOpen)

        controller.hover(.tab(TabItem(id: "t1", title: "one")), anchor: .zero, tabWidth: 100, parent: nil)
        #expect(controller.resources.target == .tab("t1"))
        for _ in 0..<100 where source.targets.isEmpty { await Task.yield() }
        #expect(source.targets == [.tab("t1")])

        // Moving to another tab restarts on that tab.
        controller.hover(.tab(TabItem(id: "t2", title: "two")), anchor: .zero, tabWidth: 100, parent: nil)
        #expect(controller.resources.target == .tab("t2"))

        controller.hide()
        #expect(!controller.resources.isOpen)
        #expect(!controller.resources.isScheduled)
    }

    @Test func groupChipsDoNotSample() {
        let source = RecordingSource()
        let controller = TabHoverCardController()
        controller.resources.setSource(source)
        let group = TabGroupItem(id: TabGroupID("g"), name: "G")
        controller.hover(.group(group, memberTitles: ["a"]), anchor: .zero, tabWidth: 100, parent: nil)
        #expect(!controller.resources.isOpen)
        controller.hide()
    }
}
