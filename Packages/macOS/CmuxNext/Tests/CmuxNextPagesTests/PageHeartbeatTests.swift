import Foundation
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

    /// Codex's review of #39247 (F1): the repair checks unsaved edits before the reload's save wait;
    /// an edit that comes during the wait (a hung editor that answers again) must not be reloaded away.
    @Test func aReloadSparesUnsavedEditsHeldWhenItsSaveWaitEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Reload</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.health-reload", resource: "health-reload", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/"))
        defer { page.close() }
        page.loaded = true
        page.holdsUnsavedEdits = { true }
        #expect(await page.reloadKeepingState(saveWait: .milliseconds(20)) == false)
    }

    @Test func aHostWithoutHealthStillAnswers() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 0]])
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
    }
}
