@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// CMD-F FIRST PRESS (user 2026-11-15, "cmd f still has bugs on first keyboard invocation (doesnt focus the
/// find text input)"): Cmd-F on a Markdown tab whose page was still loading (the first press after a launch
/// restored the tab, or right after switching to a tab whose page had not loaded) did nothing, and the second
/// press worked. The app's `find` reached the page router before the page subscribed to its command stream, so
/// ``PageRouter/publishCommand(_:arguments:now:)`` had no subscriber and dropped it. Find now waits for the
/// page: the router holds the newest `find` or `focusSearch` and delivers it when the page subscribes.
@MainActor
struct PageCommandWhileLoadingTests {
    private func commands(_ sent: [JSONValue]) -> [String] {
        sent.compactMap { $0["data"]?["command"]?.stringValue }
    }

    /// Waits (without sleeping) for the delivery the router posts after the subscribe reply.
    private func settle(_ sent: @autoclosure () -> [JSONValue], count: Int) async {
        for _ in 0..<50 where sent().count < count { await Task.yield() }
    }

    @Test func findSentBeforeThePageSubscribesReachesItWhenItDoes() async {
        let router = PageRouter(descriptor: .markdown, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        // Cmd-F while the page loads: no subscriber yet, but the page takes it once it listens.
        #expect(router.publishCommand("find", arguments: ["text": "ban"]))
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        #expect(reply["t"]?.stringValue == "ok")
        await settle(sent, count: 1)
        #expect(commands(sent) == ["find"])
        #expect(sent.first?["data"]?["text"]?.stringValue == "ban")
        // Delivered once: a later subscription (a reload) gets nothing old.
        _ = await router.handle(["t": "sub", "id": 2, "stream": .string(PageNativeOp.pageCommand)])
        await settle(sent, count: 2)
        #expect(commands(sent) == ["find"])
    }

    @Test func aListeningPageGetsTheCommandAtOnce() async {
        let router = PageRouter(descriptor: .markdown, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        _ = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        #expect(router.publishCommand("find"))
        #expect(commands(sent) == ["find"])
    }

    /// Only Find waits: Find Next, Save or Reload on a page that is not ready yet do nothing, as before.
    @Test func otherCommandsAreNotHeld() async {
        let router = PageRouter(descriptor: .markdown, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        #expect(!router.publishCommand("findNext"))
        #expect(!router.publishCommand("save"))
        _ = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        for _ in 0..<20 { await Task.yield() }
        #expect(commands(sent).isEmpty)
    }

    /// Internal pages with a search field (Settings) focus it on Cmd-F the same way.
    @Test func focusSearchWaitsToo() async {
        let router = PageRouter(descriptor: PageDescriptor(id: "cmux.held-test", resource: "held-test",
                                                           namespaces: ["cmux.held-test."]), routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        #expect(router.publishCommand("focusSearch"))
        _ = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        await settle(sent, count: 1)
        #expect(commands(sent) == ["focusSearch"])
    }

    /// A page that never loaded in time (a crash, a hang) does not open Find long after the press.
    @Test func aStaleHeldCommandIsDropped() async {
        let router = PageRouter(descriptor: .markdown, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        let pressed = ProcessInfo.processInfo.systemUptime - PageRouter.heldCommandLifetime - 1
        #expect(router.publishCommand("find", now: pressed))
        _ = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        for _ in 0..<20 { await Task.yield() }
        #expect(commands(sent).isEmpty)
    }

    /// A pooled router taken for another document forgets the command meant for the old one, and a
    /// command the page does not declare is never held.
    @Test func rebindDropsTheHeldCommandAndUnknownCommandsAreRefused() async {
        let router = PageRouter(descriptor: .markdown, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        #expect(!router.publishCommand("noSuchCommand"))
        #expect(router.publishCommand("find"))
        router.rebind(descriptor: .editor, routes: [])
        _ = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        for _ in 0..<20 { await Task.yield() }
        #expect(commands(sent).isEmpty)
    }
}
