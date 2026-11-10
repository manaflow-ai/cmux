import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// App health's page heartbeat (webviews/src/pages/shared/pageHealth.ts): every page may send
/// `cmux.page.heartbeat {handled}` with no descriptor entry, and the router hands the count to the host.
@MainActor @Suite
struct PageHeartbeatTests {
    static let descriptor = PageDescriptor(id: "cmux.heartbeat-test", resource: "heartbeat-test", namespaces: ["cmux.heartbeat."])

    @Test func anyPageBeatsAndTheHostSeesItsHandledCount() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        var beats: [UInt64] = []
        router.heartbeat = { beats.append($0) }
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 3]])
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
        #expect(beats == [3])
        // A bad count reads as none; the beat still counts.
        _ = await router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": -1]])
        _ = await router.handle(["t": "call", "id": 3, "op": .string(PageNativeOp.pageHeartbeat), "params": [:]])
        #expect(beats == [3, 0, 0])
    }

    @Test func aHostWithoutHealthStillAnswers() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 0]])
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
    }
}
