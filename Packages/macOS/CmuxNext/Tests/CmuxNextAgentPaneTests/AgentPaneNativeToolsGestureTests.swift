import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

extension AgentPaneNativeToolsHostTests {
    @Test(.timeLimit(.minutes(1))) func authenticatedNativeSelectionRenewsCreditAndReachesPage() async throws {
        let restore = enableTools()
        defer { restore() }
        final class Clock { var now: TimeInterval = 100 }
        let clock = Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        let model = AgentPaneModel(host: NoHost(), transport: AgentPaneTransport(gestures: gestures))
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: model, source: .bundled(file), pageHost: true, chromium: nil))
        defer { view.close() }
        let provider = try #require(view.pageEvents)
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self)
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                         context: PageCallContext(page: PageDescriptor.agent.id)) { sink.yield($0) }
        defer { subscription.cancel(); sink.finish() }
        let click = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                          mouseCursorPosition: .zero, mouseButton: .left))
        click.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let personEvent = try #require(NSEvent(cgEvent: click))
        gestures.record()
        clock.now += AgentPaneUserGestures.lifetime + 1
        #expect(!gestures.isAvailable)
        view.invokeTabRowTool("project", menuItemID: "instructions", event: personEvent)
        #expect(gestures.consume(), "a native selection must replace expired credit")
        #expect(!gestures.consume(), "the renewed credit is single-use")
        view.invokeTabRowTool("project", menuItemID: "addFiles", event: personEvent)
        #expect(gestures.consume(), "a later selection must replace consumed credit")
        #expect(!gestures.hasFreshAnswerGesture, "project tools must not grant permission-answer credit")
        click.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()) + 1)
        view.invokeTabRowTool("project", menuItemID: "instructions", event: try #require(NSEvent(cgEvent: click)))
        #expect(!gestures.isAvailable, "another process's posted event must not grant credit")
        view.invokeTabRowTool("project", menuItemID: nil, event: nil)
        #expect(!gestures.isAvailable, "a call outside event dispatch must not grant credit")

        var received: [JSONValue] = []
        for await event in events where event["kind"] == .string("tabRowToolInvoked") {
            received.append(event)
            if received.count == 4 { break }
        }
        #expect(received == [
            AgentPageEvent.tabRowToolInvoked(id: "project", menuItemId: "instructions").data,
            AgentPageEvent.tabRowToolInvoked(id: "project", menuItemId: "addFiles").data,
            AgentPageEvent.tabRowToolInvoked(id: "project", menuItemId: "instructions").data,
            AgentPageEvent.tabRowToolInvoked(id: "project", menuItemId: nil).data,
        ])
    }
}
