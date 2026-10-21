import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Testing

/// u5402 (Oct 20): "Make sure we can send messages in the iMessage UI via right clicking." Every
/// Send Message… entry point (a workspace, tab or agent chat's right-click, Send to Chief and Send
/// to… on selected text, Forward… on a bubble, Cmd+Shift+P, `cmux chat send`, MCP) resolves its
/// chat and writes or sends through `HomeMessageRouting`, over the HomeStore the Home chat draws.
/// The mock owner: "conv_chief" is the Chief, "conv_austin" a DM with Austin, "conv_launch" the
/// "Launch" group.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct HomeMessageRoutingTests {
    let chief = ConversationID("conv_chief")
    let austin = ConversationID("conv_austin")
    let launch = ConversationID("conv_launch")

    final class NoMuting: HomeConversationMuting {
        func canMute(_ id: ConversationID) -> Bool { false }
        func isMuted(_ id: ConversationID) -> Bool { false }
        func setMuted(_ on: Bool, _ id: ConversationID) {}
    }

    func started(chief: ConversationID? = nil) async throws -> (HomeStore, HomeMessageRouting) {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        try await until { store.isOnline && !store.rows.isEmpty }
        let actions = HomeGroupActions(store: store, muting: NoMuting(), contacts: { [] })
        return (store, HomeMessageRouting(store: store, actions: actions, chief: { chief }))
    }

    func until(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition never held")
                return
            }
            await Task.yield()
        }
    }

    @Test func toNamesAChiefAPersonAGroupOrAnID() async throws {
        let (_, routing) = try await started()
        #expect(routing.resolve("chief") == chief)
        #expect(routing.resolve("Chief") == chief)
        #expect(routing.resolve("austin") == austin)
        #expect(routing.resolve("user_austin") == austin)
        #expect(routing.resolve("launch") == launch)
        #expect(routing.resolve("conv_launch") == launch)
        #expect(routing.resolve(" Release Chief ") == ConversationID("conv_release"))
        #expect(routing.resolve("Nobody") == nil)
        #expect(routing.resolve("  ") == nil)
    }

    /// The app's Chief wins (a Chief placed on a server); without one, the first Chief listed.
    @Test func theChiefIsTheAppsChoiceElseTheFirstListed() async throws {
        let (_, routing) = try await started(chief: ConversationID("conv_infra"))
        #expect(routing.chiefConversation == ConversationID("conv_infra"))
        let (_, fallback) = try await started(chief: ConversationID("conv_gone"))
        #expect(fallback.chiefConversation == chief)
    }

    /// The palette's To: list and `--to` completions: Chiefs first, then everyone else.
    @Test func recipientsListChiefsFirst() async throws {
        let (store, routing) = try await started()
        let listed = routing.recipients()
        #expect(listed.count == store.rows.count)
        let kinds = listed.compactMap { item in store.rows.first { $0.id.rawValue == item.value }?.kind }
        let firstOther = kinds.firstIndex { $0 != .chief } ?? kinds.count
        #expect(kinds[firstOther...].allSatisfy { $0 != .chief })
        #expect(listed.contains { $0.value == "conv_launch" && $0.title == "Launch" })
    }

    /// Send to Chief puts the selection in the Chief's message box after what the person typed,
    /// never over it; a second selection goes after the first.
    @Test func selectedTextGoesIntoTheMessageBoxAsAQuote() async throws {
        let (store, routing) = try await started()
        store.setDraft("look at this", for: chief)
        let quoted = HomeMessageRouting.quoted("error: build failed\n\nat main.swift:12")
        #expect(quoted == "> error: build failed\n>\n> at main.swift:12\n\n")
        _ = routing.compose(quoted, into: chief)
        #expect(store.draft(for: chief) == "look at this\n> error: build failed\n>\n> at main.swift:12\n\n")
        _ = routing.compose(HomeMessageRouting.quoted("second"), into: chief)
        #expect(store.draft(for: chief)?.hasSuffix("at main.swift:12\n\n> second\n\n") == true)
        #expect(routing.compose("x", into: ConversationID("conv_gone")) == nil)
    }

    /// Send Message… on a workspace or tab names it as a link chip in the Chief's box.
    @Test func aWorkspaceIsNamedAsALink() async throws {
        let (store, routing) = try await started()
        let link = "cmux://workspace/ws_0123456789abcdef0123456789abcdef"
        _ = routing.compose(HomeMessageRouting.mention("Fix [flaky] tests", link: link), into: chief)
        #expect(store.draft(for: chief) == "[Fix (flaky) tests](\(link)) ")
        #expect(HomeMessageRouting.mention("  ", link: link) == "[\(link)](\(link)) ")
    }

    /// `cmux chat send --to Launch --text …` (and MCP): the message is sent through the message
    /// box's own send and lands after every message already there, in the order sent.
    @Test func chatSendPostsInOrder() async throws {
        let (store, routing) = try await started()
        await store.open(launch)
        let before = store.transcript(for: launch).count
        let to = try #require(routing.resolve("Launch"))
        #expect(await routing.send("  first  ", to: to) == .done)
        #expect(await routing.send("second", to: to) == .done)
        try await until { store.transcript(for: launch).count == before + 2 }
        let texts = store.transcript(for: launch).suffix(2).map(\.parts)
        #expect(texts == [[.text("first")], [.text("second")]])
        #expect(await routing.send("  ", to: to) == .emptyText)
    }
}
