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
        var edits: [Bool] = []
        router.heartbeat = { beats.append($0); edits.append($1); _ = $2; return true }
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 3]])
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
        #expect(beats == [3])
        // A bad count reads as none; the beat still counts.
        _ = await router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": -1]])
        _ = await router.handle(["t": "call", "id": 3, "op": .string(PageNativeOp.pageHeartbeat), "params": [:]])
        #expect(beats == [3, 0, 0])
        // A page that marks unsaved edits says so with the beat; the next beat without them clears it.
        _ = await router.handle(["t": "call", "id": 4, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 4, "edits": true]])
        #expect(edits == [false, false, false, true])
    }

    /// Codex's review of #39247 at 5e952b6 (F1): the Cloud page's file editor keeps its text only in
    /// the page; its beat's `edits` holds the page against app health's reload until a beat clears it.
    @Test func aPageThatReportsUnsavedEditsIsNotReloadedAway() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Edits</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.health-edits", resource: "health-edits", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/"))
        defer { page.close() }
        page.loaded = true
        _ = await page.router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 1, "edits": true]])
        #expect(page.holdsEdits)
        #expect(await page.reloadKeepingState(saveWait: .milliseconds(20)) == false)
        _ = await page.router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 2]])
        #expect(!page.holdsEdits)
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

    /// CMUX-571: a page with nothing happening in it rests (its last beat says `rest`) and beats no
    /// more, so an idle app wakes for no page. The page rests only on a host that answered its beat
    /// with `rest: true`; the host hands the rest to app health, which stops timing its silence.
    @Test func aRestBeatReachesTheHostAndTheReplySaysTheHostTakesRests() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        var rests: [Bool] = []
        var takes = true
        router.heartbeat = { _, _, rest in rests.append(rest); return takes }
        let beat = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 1]])
        #expect(beat["value"]?["rest"]?.boolValue == true, "\(beat)")
        _ = await router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 1, "rest": true]])
        #expect(rests == [false, true])
        // A host whose health model would time a resting page (an older pinned model) says no: the page keeps beating.
        takes = false
        let refused = await router.handle(["t": "call", "id": 3, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 1]])
        #expect(refused["value"]?["rest"]?.boolValue == false, "\(refused)")
    }

    @Test func aHostWithoutHealthStillAnswers() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.pageHeartbeat), "params": ["handled": 0]])
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
    }
}
