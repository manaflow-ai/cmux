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
    ///   - me: The signed-in person (or a debug stand-in).
    ///   - now: The newest row's time.
    public init(me: Participant, now: Date) {
        self.me = me
        self.now = now
    }

    /// One DM per name, an hour apart.
    /// - Parameters:
    ///   - count: How many of ``names`` get a DM.
    ///   - edgeText: The text edge cases on them (``edgeText(_:)``).
    public func rows(count: Int, edgeText: Bool = false) -> [InboxRow] {
        let rows = inbox(Self.names.prefix(count).enumerated().map { i, name in
            summary("conv_fixture_\(i)", "", Participant(id: ParticipantID("user_fixture_\(i)"), kind: .human, displayName: name), back: 3600 * (i + 1))
        })
        return edgeText ? Self.edgeText(rows) : rows
    }

    /// The text edge cases on `rows` (`debug.home.sidebar_fixture` `edge_text`), in turn: a long name, a preview
    /// that wraps to two lines, a one-word preview, emoji, a long unbroken word; every third row unread.
    public static func edgeText(_ rows: [InboxRow]) -> [InboxRow] {
        let previews = ["Can you look at the deploy logs from last night? The build passed but the app does not start on the staging Mac.",
                        "ok", "🚀🔥 shipped it 🎉", "https://github.com/manaflow-ai/cmux/pull/53185/files#diff-averyveryverylongunbrokenanchor",
                        "Sounds good, talk tomorrow.", "I pushed a fix for the sidebar glow and the search field outline, can you check it?"]
        return rows.enumerated().map { i, row in
            var row = row
            if i % 4 == 0 { row.title = row.title + " Montgomery-Alexander (Design)" }
            row.preview = previews[i % previews.count]
            if i % 3 == 0 { row.unread = max(row.unread, 1) }
            return row
        }
    }

    /// One DM with each Chief, a minute apart.
    /// - Parameter chiefs: Each Chief's participant id and name.
    public func chiefRows(_ chiefs: [(id: String, name: String)]) -> [InboxRow] {
        inbox(chiefs.enumerated().map { i, chief in
            summary("conv_fixture_chief_\(i)", chief.name, Participant(id: ParticipantID(chief.id), kind: .agent, displayName: chief.name, agentClass: .chief),
                    back: 60 * (i + 1))
        })
    }

    /// One channel per title (plans/cmux-next/chief-channels-DESIGN.md), each a group with its own
    /// Chief and two teammates, two minutes apart; the first is unread.
    /// - Parameter titles: The channels' names.
    public func channelRows(_ titles: [String]) -> [InboxRow] {
        inbox(titles.enumerated().map { i, title in
            let at = now.addingTimeInterval(Double(-120 * (i + 1)))
            let chief = Participant(id: ParticipantID("agent_fixture_channel_\(i)"), kind: .agent, displayName: "\(title) Chief", agentClass: .chief)
            let people = Self.names.prefix(2).enumerated().map { j, name in Participant(id: ParticipantID("user_fixture_channel_\(i)_\(j)"), kind: .human, displayName: name) }
            return ConversationSummary(id: ConversationID("conv_fixture_channel_\(i)"), title: title, participants: [me, chief] + people,
                                       lastSeq: i == 0 ? 3 : 0, createdAt: at, updatedAt: at, declaredKind: .group, channelChief: chief.id)
        })
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
