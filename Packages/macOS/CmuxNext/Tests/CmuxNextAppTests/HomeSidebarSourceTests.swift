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
