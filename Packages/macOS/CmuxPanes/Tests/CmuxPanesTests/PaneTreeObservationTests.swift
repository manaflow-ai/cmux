import Foundation
import Testing
@testable import CmuxPanes

/// Tests the `@Observable` re-arming watch that replaces the internal
/// `Workspace.panelsPublisher` `CurrentValueSubject` subscriber. The watch must
/// deliver on every mutation (including equal re-assignment), re-arm so it keeps
/// firing, optionally replay on subscribe, and stop after `cancel()`.
@MainActor
@Suite("PaneTreeObservation")
struct PaneTreeObservationTests {
    /// `fireImmediately: true` reproduces `CurrentValueSubject.sink`'s
    /// replay-on-subscribe: the handler runs once synchronously at install.
    @Test func fireImmediatelyReplaysOnSubscribe() {
        let model = PaneTreeModel<String>()
        var count = 0
        let handle = model.observePanels(fireImmediately: true) { count += 1 }
        #expect(count == 1)
        handle.cancel()
    }

    /// Without `fireImmediately` the handler does not fire until the next change.
    @Test func noReplayWhenNotRequested() {
        let model = PaneTreeModel<String>()
        var count = 0
        let handle = model.observePanels { count += 1 }
        #expect(count == 0)
        handle.cancel()
    }

    /// The watch fires after a mutation and re-arms so a second mutation also
    /// fires. Delivery is a `MainActor` hop after the change commits.
    @Test func reArmsAcrossSuccessiveMutations() async {
        let model = PaneTreeModel<String>()
        var count = 0
        let handle = model.observePanels { count += 1 }

        model.panels = [UUID(): "a"]
        await Task.yield()
        #expect(count == 1)

        model.panels = [UUID(): "b"]
        await Task.yield()
        #expect(count == 2)

        handle.cancel()
    }

    /// Equal re-assignment still fires, matching the legacy bridge's `.send`
    /// (the `@Observable` macro records a mutation on every set).
    @Test func equalReassignmentStillFires() async {
        let model = PaneTreeModel<String>()
        let id = UUID()
        model.panels = [id: "a"]

        var count = 0
        let handle = model.observePanels { count += 1 }
        model.panels = [id: "a"]
        await Task.yield()
        #expect(count == 1)
        handle.cancel()
    }

    /// After `cancel()` no further change handler fires, even across the hop.
    @Test func cancelStopsDelivery() async {
        let model = PaneTreeModel<String>()
        var count = 0
        let handle = model.observePanels { count += 1 }
        handle.cancel()
        model.panels = [UUID(): "a"]
        await Task.yield()
        #expect(count == 0)
    }
}
