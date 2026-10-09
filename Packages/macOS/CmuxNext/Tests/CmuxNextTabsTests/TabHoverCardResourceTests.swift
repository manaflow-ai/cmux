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
/// or shown: the coordinator activates the target at hover start and
/// deactivates it when the card ends.
@MainActor
@Suite struct TabHoverCardResourceTests {
    @Test func samplingStartsAtHoverStartAndStopsWhenTheCardHides() async {
        let source = RecordingSource()
        let controller = TabHoverCardController()
        controller.resources.setSource(source)
        #expect(!controller.resources.isOpen)

        controller.hoverCardActivated(TabHoverCardController.targetID("t1"))
        #expect(controller.resources.target == .tab("t1"))
        for _ in 0..<100 where source.targets.isEmpty { await Task.yield() }
        #expect(source.targets == [.tab("t1")])

        // Moving to another tab restarts on that tab.
        controller.hoverCardDeactivated(TabHoverCardController.targetID("t1"))
        controller.hoverCardActivated(TabHoverCardController.targetID("t2"))
        #expect(controller.resources.target == .tab("t2"))

        controller.hoverCardDeactivated(TabHoverCardController.targetID("t2"))
        #expect(!controller.resources.isOpen)
        #expect(!controller.resources.isScheduled)
    }

    /// A tab with no numbers to report (an agent chat, the New Tab page)
    /// shows no resource line instead of "Resource usage unavailable".
    @Test func aTabWithoutResourceNumbersShowsNoResourceLine() {
        let body = TabHoverCardView()
        body.configure(.tab(TabItem(id: TabID("t1"), title: "Agent")))
        body.setResources(ResourceReport(tabs: [TabResourceReport(
            id: "t1", title: "Agent", kind: .other, usage: .zero, processCount: 0, sharedWithTabs: 0, available: false
        )]))
        #expect(body.resources.isHidden)

        body.setResources(ResourceReport(tabs: [TabResourceReport(
            id: "t1", title: "Agent", kind: .terminal, usage: .zero, processCount: 1, sharedWithTabs: 0, available: true
        )]))
        #expect(!body.resources.isHidden)
    }

    @Test func groupChipsDoNotSample() {
        let source = RecordingSource()
        let controller = TabHoverCardController()
        controller.resources.setSource(source)
        controller.hoverCardActivated(TabHoverCardController.targetID(.groupChip(TabGroupID("g"))))
        #expect(!controller.resources.isOpen)
    }
}
