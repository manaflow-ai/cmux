import CmuxHomeCore
import CmuxHomeRender
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A widget host with fixed snapshots that records what the page provider asks of it.
@MainActor
private final class FakeWidgetHost: HomeWidgetHosting {
    var snapshots: [String: HomeWidgetSnapshot] = [:]
    var asked: [(String, ChatWidget)] = []
    var taps: [(String, String)] = []
    var kept: [ObjectIdentifier: Set<String>] = [:]
    private var sinks: [AsyncStream<String>.Continuation] = []

    func snapshot(for key: String, widget: ChatWidget) -> HomeWidgetSnapshot? {
        asked.append((key, widget))
        return snapshots[key]
    }
    func tap(key: String, node: String) { taps.append((key, node)) }
    func keep(_ keys: Set<String>, owner: ObjectIdentifier) { kept[owner] = keys }
    func changes() -> AsyncStream<String> {
        let (stream, sink) = AsyncStream<String>.makeStream()
        sinks.append(sink)
        return stream
    }
    func change(_ key: String) { for sink in sinks { sink.yield(key) } }
}

/// The Messages page's chat widget ops (HomeMessagesWidgets; the native rows' cases,
/// MessagesLabHomeTests `HomeWidgetRowTests`).
@MainActor
struct HomeMessagesWidgetsTests {
    static let card = HomeWidgetSnapshot(items: [
        .text("Widgets in chat", style: .headline),
        .row(node: "pr", title: "o/r #7", subtitle: "Open · octo", symbol: "arrow.triangle.pull", tint: .success),
        .badge("1 failed · 6 passed", tint: .danger),
        .divider,
        .row(node: nil, title: "check-7", tint: .danger),
        .buttons([HomeWidgetButton(node: "prev", title: "Previous", enabled: false),
                  HomeWidgetButton(node: "next", title: "Next", prominent: true)]),
        .empty(title: "No checks", message: nil, symbol: "clock"),
    ])
    static let part: JSONValue = .object([
        "app": "cmux/pr-card", "widget": "cmux.chat.widget/1",
        "props": .object(["repo": "o/r", "number": .number(7)]),
        "fallback": "PR #7: Widgets in chat",
    ])
    static let page = PageCallContext(page: "cmux.home-messages")
    static let click = PageCallContext(page: "cmux.home-messages", userGesture: true)
    static let op = HomeMessagesWidgets.prefix

    @Test func aSnapshotIsTheCardsItemsAndKeepsItsKey() async throws {
        let host = FakeWidgetHost()
        host.snapshots["msg_1#1"] = Self.card
        let widgets = HomeMessagesWidgets(host: host, personOnlyMessage: "click")
        let answer = try await widgets.call(Self.op + ".snapshot", params: .object(["key": "msg_1#1", "widget": Self.part]), context: Self.page)
        let items = try #require(answer["items"]?.arrayValue)
        #expect(items.count == 7)
        #expect(items[0] == .object(["type": "text", "text": "Widgets in chat", "style": "headline", "tint": "primary"]))
        #expect(items[1] == .object(["type": "row", "node": "pr", "title": "o/r #7", "subtitle": "Open · octo",
                                     "symbol": "arrow.triangle.pull", "tint": "success"]))
        #expect(items[2] == .object(["type": "badge", "text": "1 failed · 6 passed", "tint": "danger"]))
        #expect(items[3] == .object(["type": "divider"]))
        // A row with no node takes no click: the page reads no node.
        #expect(items[4] == .object(["type": "row", "title": "check-7", "tint": "danger"]))
        #expect(items[5] == .object(["type": "buttons", "buttons": .array([
            .object(["node": "prev", "title": "Previous", "prominent": .bool(false), "enabled": .bool(false)]),
            .object(["node": "next", "title": "Next", "prominent": .bool(true), "enabled": .bool(true)]),
        ])]))
        #expect(items[6] == .object(["type": "empty", "title": "No checks", "symbol": "clock"]))
        // The part the host mounts: props as JSON text, sorted.
        let asked = try #require(host.asked.first)
        #expect(asked.0 == "msg_1#1")
        #expect(asked.1 == ChatWidget(app: "cmux/pr-card", propsJSON: #"{"number":7,"repo":"o/r"}"#, fallback: "PR #7: Widgets in chat"))
        #expect(host.kept[ObjectIdentifier(widgets)] == ["msg_1#1"])
    }

    @Test func aWidgetWithoutASnapshotOrWithoutAHostIsNullAndABadPartIsRefused() async throws {
        let host = FakeWidgetHost()
        let widgets = HomeMessagesWidgets(host: host, personOnlyMessage: "click")
        #expect(try await widgets.call(Self.op + ".snapshot", params: .object(["key": "msg_1#0", "widget": Self.part]), context: Self.page) == .null)
        let none = HomeMessagesWidgets(host: { nil }, personOnlyMessage: "click")
        #expect(try await none.call(Self.op + ".snapshot", params: .object(["key": "msg_1#0", "widget": Self.part]), context: Self.page) == .null)
        await #expect(throws: PageError.self) {
            _ = try await widgets.call(Self.op + ".snapshot", params: .object(["key": "msg_1#0", "widget": .object(["app": "cmux/pr-card"])]),
                                       context: Self.page)
        }
    }

    @Test func aTapIsAClickOnly() async throws {
        let host = FakeWidgetHost()
        let widgets = HomeMessagesWidgets(host: host, personOnlyMessage: "click")
        let tap: JSONValue = .object(["key": "msg_1#0", "node": "next"])
        await #expect(throws: PageError.self) { _ = try await widgets.call(Self.op + ".tap", params: tap, context: Self.page) }
        #expect(host.taps.isEmpty)
        _ = try await widgets.call(Self.op + ".tap", params: tap, context: Self.click)
        #expect(host.taps.map(\.1) == ["next"])
        #expect(host.taps.allSatisfy { $0.0 == "msg_1#0" })
    }

    @Test func keepReplacesTheKeysAndClosingReleasesThem() async throws {
        let host = FakeWidgetHost()
        let widgets = HomeMessagesWidgets(host: host, personOnlyMessage: "click")
        let owner = ObjectIdentifier(widgets)
        _ = try await widgets.call(Self.op + ".keep", params: .object(["keys": .array(["a#0", "b#1"])]), context: Self.page)
        #expect(host.kept[owner] == ["a#0", "b#1"])
        _ = try await widgets.call(Self.op + ".keep", params: .object(["keys": .array(["b#1"])]), context: Self.page)
        #expect(host.kept[owner] == ["b#1"])
        widgets.pageDidClose()
        #expect(host.kept[owner] == [])
    }

    @Test func aSceneChangeSendsTheNewSnapshot() async throws {
        let host = FakeWidgetHost()
        let widgets = HomeMessagesWidgets(host: host, personOnlyMessage: "click")
        _ = try await widgets.call(Self.op + ".snapshot", params: .object(["key": "msg_1#0", "widget": Self.part]), context: Self.page)
        let (events, sink) = AsyncStream<JSONValue>.makeStream()
        let subscription = try await widgets.subscribe(Self.op, filter: .object([:]), context: Self.page) { _ = sink.yield($0) }
        defer { subscription.cancel() }
        host.snapshots["msg_1#0"] = HomeWidgetSnapshot(items: [.text("Page 2 of 2", style: .caption, tint: .secondary)])
        host.change("msg_1#0")
        var iterator = events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event["key"] == "msg_1#0")
        #expect(event["snapshot"]?["items"]?.arrayValue?.first == .object(["type": "text", "text": "Page 2 of 2", "style": "caption", "tint": "secondary"]))
    }
}
