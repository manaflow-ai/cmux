import AppKit
import CmuxNextResources
import Testing
@testable import CmuxNextSidebar

@MainActor
private final class RecordingSource: ResourceSampleSource {
    var targets: [ResourceTarget] = []
    func sample(_ target: ResourceTarget) async -> ResourceSampleSet {
        targets.append(target)
        return .empty
    }
}

/// The workspace hover card samples the workspace's CPU and memory from
/// hover start until the card hides, and never otherwise.
@MainActor
@Suite struct WorkspaceHoverCardTests {
    @Test func samplingStartsAtHoverStartAndStopsWhenTheCardHides() async {
        let source = RecordingSource()
        let controller = WorkspaceHoverCardController()
        controller.resources.setSource(source)
        #expect(!controller.resources.isOpen)

        controller.hover(w("a"), anchor: .zero, parent: nil)
        #expect(controller.resources.target == .workspace("a"))
        for _ in 0..<100 where source.targets.isEmpty { await Task.yield() }
        #expect(source.targets == [.workspace("a")])

        controller.hide()
        #expect(!controller.resources.isOpen)
        #expect(!controller.resources.isScheduled)
    }
}
