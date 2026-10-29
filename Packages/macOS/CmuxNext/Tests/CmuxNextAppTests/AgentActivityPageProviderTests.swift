import CmuxNextAgentActivity
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The Agent Activity page on the shared page host: its requests are page ops and its state a
/// stream, so the page runs in either engine (``AgentActivityPageProvider``).
@MainActor
@Suite struct AgentActivityPageProviderTests {
    private let context = PageCallContext(page: PageDescriptor.agentActivity.id)

    @Test func aRequestRunsOnTheModelAndAFailedOneIsAPageError() async throws {
        let source = AgentActivityMockSource()
        let model = AgentActivityModel(source: source, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let provider = AgentActivityPageProvider(requests: AgentActivityRequests(model: model, source: source),
                                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        _ = try await provider.call("cmux.agentActivity.filter", params: ["value": "safari"], context: context)
        #expect(model.filter == "safari")
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.agentActivity.nope", params: [:], context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.other.filter", params: [:], context: context)
        }
    }

    @Test func theStateStreamStartsWithTheWholeStateAndFollowsChanges() async throws {
        let source = AgentActivityMockSource()
        let model = AgentActivityModel(source: source, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let provider = AgentActivityPageProvider(requests: AgentActivityRequests(model: model, source: source),
                                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var states: [JSONValue] = []
        var next: CheckedContinuation<Void, Never>?
        let subscription = try await provider.subscribe(AgentActivityPageProvider.stateStream, filter: [:], context: context) { state in
            states.append(state)
            next?.resume()
            next = nil
        }
        #expect(states.count == 1)
        #expect(states.first?.objectValue?["filter"] == .string(""))
        await withCheckedContinuation { continuation in
            next = continuation
            model.filter = "mail"
        }
        #expect(states.last?.objectValue?["filter"] == .string("mail"))
        subscription.cancel()
    }

    /// The page imports the shared React from the pages' `_shared`, so the launch
    /// registration also maps it into a web update: page and React come from the same tree. Vacuous in a
    /// test bundle built without the Activity page.
    @Test func theLaunchRegistrationServesThePageFromTheActiveUpdate() async {
        let overlay = WebBundleOverlay(bases: [])
        guard let root = PageDescriptor.registerAgentActivityRoot(overlay: overlay) else { return }
        let tree = URL(fileURLWithPath: "/Support/web-updates/trees/abc", isDirectory: true)
        overlay.activate(tree)
        #expect(await overlay.root(for: root).path == tree.path + "/" + WebBundleOverlay.agentActivityOutput)
    }
}
