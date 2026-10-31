#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxHomeCore
public import Foundation

/// DEBUG ONLY: fixture inbox rows for the Home list (`debug.home.sidebar_fixture`), built through
/// the same mirror path real inbox rows take, so captures and pin drags run on a window whose
/// account has only its Chief.
public struct HomeSidebarFixtureRows: Sendable {
    /// The fixture people's names, in list order.
    public static let names = ["Austin", "Lucas Wang", "Aziz Ali", "Mia Chen", "Noah Park", "Iris Lee",
                        "Omar Diaz", "Zoe Kim", "Sam Fox", "Ana Ruiz", "Leo Moss", "Ivy Hart"]
    /// Me in every fixture conversation.
    public let me: Participant
    /// The newest row's time; older rows step back from it.
    public let now: Date

    /// - Parameters:
    ///   - me: The signed-in person; nil stands in a debug "Me".
    ///   - now: The newest row's time.
    public init(me: Participant?, now: Date) {
        self.me = me ?? Participant(id: ParticipantID("user_debug_me"), kind: .human, displayName: "Me")
        self.now = now
    }

    /// The first `count` fixture names as team members with no DM (`debug.home.sidebar_fixture`
    /// `team`), the last name first.
    public static func team(_ count: Int) -> [HomeContact] {
        names.prefix(max(0, count)).reversed().enumerated().map { i, name in
            HomeContact(id: ParticipantID("user_fixture_team_\(i)"), name: name, source: .team)
        }
    }

    /// One DM per name, an hour apart.
    /// - Parameter count: How many of ``names`` get a DM.
    public func rows(count: Int) -> [InboxRow] {
        inbox(Self.names.prefix(count).enumerated().map { i, name in
            summary("conv_fixture_\(i)", "", Participant(id: ParticipantID("user_fixture_\(i)"), kind: .human, displayName: name), back: 3600 * (i + 1))
        })
    }

    /// One DM with each Chief, a minute apart.
    /// - Parameter chiefs: Each Chief's participant id and name.
    public func chiefRows(_ chiefs: [(id: String, name: String)]) -> [InboxRow] {
        inbox(chiefs.enumerated().map { i, chief in
            summary("conv_fixture_chief_\(i)", chief.name, Participant(id: ParticipantID(chief.id), kind: .agent, displayName: chief.name, agentClass: .chief),
                    back: 60 * (i + 1))
        })
    }

    /// The list's message search fixture (`debug.home.sidebar_fixture` `messages` [{row, text}],
    /// ``HomeSidebarView/debugMessageHits``): each text as a message in `rows[row]`, an hour apart,
    /// newest first; an entry naming no row or no text is left out. A message containing every
    /// typed word matches. No entries gives nil: the search goes back to the owner.
    /// - Parameters:
    ///   - entries: Each message's row index in `rows` and its text, as the request gave them.
    ///   - rows: The fixture rows the list shows.
    ///   - now: The newest message's time.
    public static func messageHits(_ entries: [(row: Int?, text: String?)], in rows: [InboxRow], now: Date) -> [HomeSearchHit]? {
        guard !entries.isEmpty else { return nil }
        return entries.enumerated().compactMap { i, entry -> HomeSearchHit? in
            guard let row = entry.row, rows.indices.contains(row), let text = entry.text else { return nil }
            let conversation = rows[row].id // checked: indices.contains above
            let message = Message(id: MessageID("msg_fixture_\(i)"), conversation: conversation, seq: Seq(i + 1),
                                  clientMessageID: IdempotencyKey("msg_fixture_\(i)"), author: ParticipantID("user_fixture_\(row)"),
                                  parts: [.text(text)], createdAt: now.addingTimeInterval(Double(-(i + 1) * 3600)))
            return HomeSearchHit(conversation: conversation, message: message, highlights: [])
        }
    }

    private func summary(_ id: String, _ title: String, _ other: Participant, back seconds: Int) -> ConversationSummary {
        let at = now.addingTimeInterval(Double(-seconds))
        return ConversationSummary(id: ConversationID(id), title: title, participants: [me, other], createdAt: at, updatedAt: at)
    }

    private func inbox(_ summaries: [ConversationSummary]) -> [InboxRow] {
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }
}
#endif
