@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// Home's New Cloud Machine (webviews/src/pages/home-channels ConversationList): the page reaches the
/// app's own `newCloudMachine` action through `cmux.app.action.run`, and no other app action. The
/// person's click runs it as theirs (a `user` call), so the handler opens its setup sheet and sign-in
/// as from the palette; page script, or the same click again, stays a `page` call.
@MainActor
struct HomeChannelsCloudEntryTests {
    /// The native provider's side: the context each call reached it with.
    private final class Recorder: PageProvider {
        var contexts: [PageCallContext] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            contexts.append(context)
            return ["ran": .bool(true)]
        }
    }

    @Test func theChannelsPageRunsOnlyNewCloudMachine() {
        let page = PageDescriptor.homeChannels
        #expect(page.admits(PageNativeOp.actionRun))
        #expect(page.actions == ["newCloudMachine"])
        #expect(page.gestureActions == ["newCloudMachine"])
        #expect(page.confirmedOps.isEmpty)
    }

    @Test func onlyThePersonsFreshClickRunsItAsTheirs() async throws {
        let page = PageDescriptor.homeChannels
        let recorder = Recorder()
        let provider = PageGestureActionProvider(page: page, wrapping: recorder)
        let run: JSONValue = ["action": "newCloudMachine"]
        let click = PageCallContext(page: page.id, userGesture: true, gestureEvent: 7_001)

        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: PageCallContext(page: page.id))
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
        _ = try await provider.call(PageNativeOp.actionRun, params: ["action": "history.open"],
                                    context: PageCallContext(page: page.id, userGesture: true, gestureEvent: 7_002))
        #expect(recorder.contexts.map(\.isConfirmedUser) == [false, true, false, false],
                "page script alone, the click, the same click again, an action not listed")
    }

    @Test func aPageCannotListAGestureActionItDoesNotRun() {
        let page = PageDescriptor(id: "cmux.test-gesture", resource: "x", namespaces: [], gestureActions: ["newCloudMachine"])
        #expect(page.gestureActions.isEmpty)
    }
}
