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

    @Test func groupChipsDoNotSample() {
        let source = RecordingSource()
        let controller = TabHoverCardController()
        controller.resources.setSource(source)
        controller.hoverCardActivated(TabHoverCardController.targetID(.groupChip(TabGroupID("g"))))
        #expect(!controller.resources.isOpen)
    }
}
