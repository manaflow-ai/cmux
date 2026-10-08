@testable import CmuxHomeCore
import CmuxNextHome
import Foundation
import Testing
@testable import CmuxNextApp

/// The Home sidebar's data source: pins kept per account on this Mac (the
/// daemon refuses inbox.pin), the model from the store's rows, the search,
/// and the user's choices reaching the page.
@MainActor
@Suite struct HomeSidebarSourceTests {
    static let me = ParticipantID("user_me")
    static let at = Date(timeIntervalSince1970: 1_791_324_000)

    static func row(_ id: String, _ name: String, minutesAgo: Double) -> InboxRow {
        let summary = ConversationSummary(id: ConversationID(id), participants: [Participant(id: me, kind: .human, displayName: "Me"),
                                                                                 Participant(id: ParticipantID("user_\(id)"), kind: .human, displayName: name)],
                                          createdAt: at, updatedAt: at.addingTimeInterval(-minutesAgo * 60))
        return InboxRow(summary: summary, kind: summary.kind(me: me), title: name, preview: "", previewAttachments: nil, previewAuthor: nil,
                        timestamp: summary.updatedAt, unread: 0, isPinned: false, isSending: false, hasFailedSend: false, isTyping: false)
    }

    static func defaults() -> UserDefaults {
        let name = "home-sidebar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func pinsPersistPerAccount() {
        let store = HomePinStore(defaults: Self.defaults())
        store.save(HomePins(pinned: [ConversationID("conv_a")], unpinned: [ConversationID("conv_chief")]), account: "user_1")
        #expect(store.pins(account: "user_1") == HomePins(pinned: [ConversationID("conv_a")], unpinned: [ConversationID("conv_chief")]))
        #expect(store.pins(account: "user_2") == HomePins(), "another account has its own pins")
    }

    @Test func pinningMovesARowToTheGridAndSurvivesARelaunch() {
        let defaults = Self.defaults()
        let rows = [Self.row("a", "Austin", minutesAgo: 1), Self.row("b", "Aziz", minutesAgo: 2)]
        func source() -> HomeSidebarSource {
            HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { "user_1" }, rows: { rows }, me: { Self.me },
                              contacts: { [] })
        }
        let first = source()
        first.reloadPins()
        first.setPinned(true, ConversationID("b"))
        #expect(first.model(now: Self.at).pinned.map(\.id.rawValue) == ["b"])
        #expect(first.model(now: Self.at).rows.map(\.id.rawValue) == ["a"])
        let relaunched = source()
        relaunched.reloadPins()
        #expect(relaunched.model(now: Self.at).pinned.map(\.id.rawValue) == ["b"])
        relaunched.setPinned(false, ConversationID("b"))
        #expect(relaunched.model(now: Self.at).pinned.isEmpty)
    }

    /// A dragged tile's new place is kept with the pins (this Mac's defaults, per account) and survives a relaunch.
    @Test func aDraggedOrderSurvivesARelaunch() {
        let defaults = Self.defaults()
        let rows = [Self.row("a", "Austin", minutesAgo: 1), Self.row("b", "Aziz", minutesAgo: 2), Self.row("c", "Lucas", minutesAgo: 3)]
        func source() -> HomeSidebarSource {
            HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { "user_1" }, rows: { rows }, me: { Self.me },
                              contacts: { [] })
        }
        let first = source()
        first.reloadPins()
        for id in ["a", "b", "c"] { first.setPinned(true, ConversationID(id)) }
        first.place(ConversationID("a"), at: 2)
        #expect(first.model(now: Self.at).pinned.map(\.id.rawValue) == ["b", "c", "a"])
        let relaunched = source()
        relaunched.reloadPins()
        #expect(relaunched.model(now: Self.at).pinned.map(\.id.rawValue) == ["b", "c", "a"])
        relaunched.place(ConversationID("c"), at: 0)
        let again = source()
        again.reloadPins()
        #expect(again.model(now: Self.at).pinned.map(\.id.rawValue) == ["c", "b", "a"])
    }

    /// A row dropped into the grid is pinned at the drop position, also after a relaunch.
    @Test func aRowDroppedIntoTheGridIsPinnedThere() {
        let defaults = Self.defaults()
        let rows = [Self.row("a", "Austin", minutesAgo: 1), Self.row("b", "Aziz", minutesAgo: 2), Self.row("c", "Lucas", minutesAgo: 3)]
        let source = HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { "user_1" }, rows: { rows },
                                       me: { Self.me }, contacts: { [] })
        source.reloadPins()
        source.setPinned(true, ConversationID("a"))
        source.setPinned(true, ConversationID("b"))
        source.place(ConversationID("c"), at: 1)
        #expect(source.model(now: Self.at).pinned.map(\.id.rawValue) == ["a", "c", "b"])
        #expect(source.model(now: Self.at).rows.isEmpty)
        #expect(HomePinStore(defaults: defaults).pins(account: "user_1").pinned.map(\.rawValue) == ["a", "c", "b"])
    }

    @Test func choicesReachThePageAndSearchFilters() {
        let rows = [Self.row("a", "Austin", minutesAgo: 1), Self.row("b", "Aziz", minutesAgo: 2)]
        let zoe = HomeContact(id: ParticipantID("user_zoe"), name: "Zoe", source: .team)
        let source = HomeSidebarSource(store: HomePinStore(defaults: Self.defaults()), account: { "user_1" }, rows: { rows },
                                       me: { Self.me }, contacts: { [zoe] })
        var selected: [String] = []
        var started: [String] = []
        source.onSelect = { selected.append($0.rawValue) }
        source.onStart = { started.append($0.name) }
        source.select(ConversationID("a"))
        source.start(with: zoe)
        #expect(selected == ["a"] && started == ["Zoe"])
        source.query = "zi"
        #expect(source.model(now: Self.at).rows.map(\.id.rawValue) == ["b"])
        source.query = "zo"
        #expect(source.model(now: Self.at).people.map(\.name) == ["Zoe"])
    }
}
