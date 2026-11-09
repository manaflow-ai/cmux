import AppKit
import CmuxHomeRender
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Chat Colors… is a React page (webviews/src/pages/home-chat-colors) on `cmux.home.chatColors.*`:
/// a pick runs `HomeChatColorStore.set` (the code `cmux chat colors` runs), a change from elsewhere
/// while the panel is open streams the new state, Reset clears the chat, a call for an older session
/// changes nothing, and the panel is 340 pt wide with the chat's name in its title.
@MainActor @Suite(.serialized) struct HomeChatColorsPanelTests {
    private static let context = PageCallContext(page: "cmux.home-chat-colors", userGesture: true)
    private static let prefix = HomeChatColorsProvider.prefix

    private struct Rig {
        let store: HomeChatColorStore
        let provider: HomeChatColorsProvider
        let session: HomeChatColorsProvider.Session
    }

    private func rig() throws -> Rig {
        let defaults = try #require(UserDefaults(testSuiteName: "HomeChatColorsPanelTests.\(UUID().uuidString)"))
        let store = HomeChatColorStore(defaults: defaults)
        let provider = HomeChatColorsProvider(store: store, design: DesignSettings())
        let session = HomeChatColorsProvider.Session(id: "s1", conversation: "chat", name: "Ada")
        provider.begin(session)
        return Rig(store: store, provider: provider, session: session)
    }

    private func call(_ rig: Rig, _ op: String, _ params: [String: JSONValue] = [:], session: String? = nil) async throws {
        var params = params
        params["session"] = .string(session ?? rig.session.id)
        _ = try await rig.provider.call(Self.prefix + op, params: .object(params), context: Self.context)
    }

    /// The store's change reaches the stream on a later main-actor turn (Observation's onChange):
    /// waits for `condition`, at most two seconds.
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The events a stream sent, in order.
    @MainActor private final class Events {
        var list: [JSONValue] = []
        var last: JSONValue? { list.last }
        var count: Int { list.count }
    }

    private func color(_ event: JSONValue?, _ role: String) -> String? { event?["colors"]?[role]?.stringValue }

    @Test func aPickRunsTheStoreSetAndDefaultClearsIt() async throws {
        let rig = try rig()
        try await call(rig, "set", ["role": .string("sent"), "color": .string("#34C759")])
        #expect(rig.store.colors(for: "chat").hexSummary == "sent=#34C759")
        try await call(rig, "set", ["role": .string("sentText"), "color": .string("#000000")])
        try await call(rig, "set", ["role": .string("sent"), "color": .null])
        #expect(rig.store.colors(for: "chat").hexSummary == "sentText=#000000")
        try await call(rig, "reset")
        #expect(rig.store.colors(for: "chat").isEmpty)
        await #expect(throws: PageError.self) {
            try await call(rig, "set", ["role": .string("sent"), "color": .string("blue")])
        }
    }

    @Test func aCallForAnOlderSessionChangesNothing() async throws {
        let rig = try rig()
        rig.provider.begin(HomeChatColorsProvider.Session(id: "s2", conversation: "other", name: "Bo"))
        await #expect(throws: PageError.cancelled) {
            try await call(rig, "set", ["role": .string("sent"), "color": .string("#34C759")], session: "s1")
        }
        #expect(rig.store.colors(for: "chat").isEmpty)
        rig.provider.end()
        await #expect(throws: PageError.cancelled) {
            try await call(rig, "reset", session: "s2")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aChangeFromTheCLIWhileOpenStreamsTheNewState() async throws {
        let rig = try rig()
        let events = Events()
        let subscription = try await rig.provider.subscribe(HomeChatColorsProvider.stateStream, filter: .object([:]),
                                                            context: Self.context) { events.list.append($0) }
        defer { subscription.cancel() }
        let first = try #require(events.last)
        #expect(first["session"]?.stringValue == "s1")
        #expect(first["colors"]?["received"] == .null)
        #expect(first["preview"]?["sent"]?["fill"]?.stringValue?.hasPrefix("#") == true)
        // `cmux chat colors --received #1C2A4A` runs the store's apply.
        try rig.store.apply(["received": "#1C2A4A", "receivedText": "#FFFFFF"], reset: false, to: "chat")
        await settle { color(events.last, "received") == "#1C2A4A" }
        #expect(color(events.last, "received") == "#1C2A4A")
        #expect(events.last?["preview"]?["received"]?["fill"]?.stringValue == "#1C2A4A")
        // A pick on the page streams back the same way.
        try await call(rig, "set", ["role": .string("sent"), "color": .string("#AF52DE")])
        await settle { color(events.last, "sent") == "#AF52DE" }
        #expect(color(events.last, "sent") == "#AF52DE")
        // Closed: the loop that streamed the state is over, so a later change sends nothing.
        let loop = try #require(rig.provider.following)
        rig.provider.end()
        await loop.value
        let count = events.count
        try rig.store.apply([:], reset: true, to: "chat")
        #expect(events.count == count)
    }

    @Test func aNewOpenSendsItsSessionAndState() async throws {
        let rig = try rig()
        let sessions = Events()
        let states = Events()
        let a = try await rig.provider.subscribe(HomeChatColorsProvider.sessionStream, filter: .object([:]),
                                                 context: Self.context) { sessions.list.append($0) }
        let b = try await rig.provider.subscribe(HomeChatColorsProvider.stateStream, filter: .object([:]),
                                                 context: Self.context) { states.list.append($0) }
        defer { a.cancel(); b.cancel() }
        #expect(sessions.last?["name"]?.stringValue == "Ada")
        rig.provider.begin(HomeChatColorsProvider.Session(id: "s2", conversation: "other", name: "Bo"))
        #expect(sessions.last?["id"]?.stringValue == "s2")
        #expect(states.last?["session"]?.stringValue == "s2")
    }

    @Test func customColorStartsFromTheColourTheRoleDraws() async throws {
        let rig = try rig()
        var opened: (HomeChatColorsProvider.Role, HomeColor)?
        rig.provider.onCustomColor = { opened = ($0, $1) }
        try await call(rig, "customColor", ["role": .string("received")])
        let resolved = rig.provider.preview(HomeBubbleColors()).received.fill
        #expect(opened?.0 == .received)
        #expect(opened?.1 == resolved)
        try rig.store.apply(["received": "#D9F7E0"], reset: false, to: "chat")
        try await call(rig, "customColor", ["role": .string("received")])
        #expect(opened?.1.hex == "#D9F7E0")
        // The colour panel's pick goes through the store.
        rig.provider.pick(.received, HomeColor(hex: "#123456"))
        #expect(rig.store.colors(for: "chat").hexSummary == "received=#123456")
    }

    @Test func thePanelIs340WideWithTheChatsNameAndDoneClosesIt() async throws {
        let defaults = try #require(UserDefaults(testSuiteName: "HomeChatColorsPanelTests.\(UUID().uuidString)"))
        let service = HomeChatColorsService(store: HomeChatColorStore(defaults: defaults), design: DesignSettings())
        service.show(conversation: "chat", name: "Ada", over: nil)
        let window = try #require(service.window)
        defer { window.orderOut(nil) }
        #expect(window.title == "Chat Colors — Ada")
        #expect(window.contentView?.frame.width == 340)
        let session = try #require(service.provider.session)
        _ = try await service.provider.call(Self.prefix + "done", params: .object(["session": .string(session.id)]), context: Self.context)
        #expect(!window.isVisible)
        #expect(service.provider.session == nil)
    }

    /// The page is zoomed by `app.uiScale`; at 1.5x the panel is 510 pt so the 340 CSS px layout
    /// (every swatch row through Custom Color) still fits, and a scale change resizes it.
    @Test func thePanelGrowsWithThePageZoom() async throws {
        let design = DesignSettings.shared
        let saved = design.uiScale
        defer { design.uiScale = saved }
        design.uiScale = 1.5
        #expect(HomeChatColorsService.contentSize(zoom: 1.5) == NSSize(width: 510, height: 510))
        let defaults = try #require(UserDefaults(testSuiteName: "HomeChatColorsPanelTests.\(UUID().uuidString)"))
        let service = HomeChatColorsService(store: HomeChatColorStore(defaults: defaults), design: design)
        service.show(conversation: "chat", name: "Ada", over: nil)
        let window = try #require(service.window)
        defer { window.orderOut(nil) }
        #expect(window.contentView?.frame.size == NSSize(width: 510, height: 510))
        design.uiScale = 1
        await settle { window.contentView?.frame.width == 340 }
        #expect(window.contentView?.frame.size == NSSize(width: 340, height: 340))
    }
}
