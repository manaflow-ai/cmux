public import Foundation

/// Confirmed history behind a mock source: seqs 1...count, read by page.
public nonisolated protocol HomeMockHistory: Sendable {
    var count: Int { get }
    /// Messages with seq in `range` (1-based), ascending.
    func messages(in range: Range<Int>) async -> [HomeMessage]
}

/// An in-memory history (tests, the demo's small conversations).
public nonisolated struct HomeMemoryHistory: HomeMockHistory {
    public let all: [HomeMessage]

    public init(_ messages: [HomeMessage]) { all = messages }

    public var count: Int { all.count }

    public func messages(in range: Range<Int>) async -> [HomeMessage] {
        let lo = max(1, range.lowerBound), hi = min(all.count + 1, range.upperBound)
        guard lo < hi else { return [] }
        return Array(all[(lo - 1)..<(hi - 1)])
    }

    /// A deterministic conversation that shows every row kind: groups and
    /// tails, time separators, a mention, work cards, a fallback part, a
    /// retracted message, reactions and an edit.
    public static func sample(me: String, agent: String, other: String, count: Int = 240,
                              now: Date = Date()) -> HomeMemoryHistory {
        let lines = [
            "Can you look at why the nightly failed?",
            "On it. The release compile step timed out on the fleet.",
            "Which host?",
            "aws-m4pro-4. Its caches are broken again, so SwiftPM resolve fails.",
            "Pin it to austins-mac-mini and rerun.",
            "Done. Rerunning now, about 20 minutes.",
            "Thanks! Also, can you summarize what changed in the sidebar today?",
            "Three PRs: row hover, group collapse animation, and the drag gap fix.",
            "Nice. Ship the drag gap fix first.",
            "Ok 👍",
        ]
        var messages: [HomeMessage] = []
        var time = now.addingTimeInterval(-Double(count) * 40 - Double(count / 12 + 1) * 3600)
        for i in 0..<count {
            let seq = i + 1
            let pattern = i % 10
            let author = pattern % 2 == 0 ? me : (i % 30 == 7 ? other : agent)
            var parts: [HomePart] = [.text(lines[pattern])]
            if pattern == 5, i % 20 == 5 {
                parts.append(.work(session: "nightly-release-compile", status: i % 40 == 5 ? .running : .done,
                                   preview: "xcodebuild -scheme CmuxNext -configuration Release"))
            }
            if i % 37 == 11 { parts = [.fallback("build-log-\(seq).txt")] }
            if i % 23 == 3 {
                let text = "@Mux can you check this?"
                parts = [.text(text, mentions: [HomeMention(start: 0, length: 4, participantID: agent)])]
            }
            // gaps: a separator every 12 messages, a group gap otherwise
            time = time.addingTimeInterval(i % 12 == 0 ? 3600 : (pattern % 2 == 0 ? 50 : 20))
            let createdAt = time
            var message = HomeMessage(id: "msg_\(seq)", seq: seq, clientMsgID: "c\(seq)", authorID: author, parts: parts,
                                      createdAt: createdAt, delivery: author == me ? .sent : .none)
            if i % 17 == 4 { message.reactions = [HomeReaction(authorID: author == me ? agent : me, kind: "like")] }
            if i % 29 == 9 { message.reactions = [HomeReaction(authorID: me, kind: "love"), HomeReaction(authorID: other, kind: "laugh")] }
            if i % 41 == 13 { message.retractedAt = createdAt.addingTimeInterval(30); message.parts = [] }
            if i % 31 == 2 { message.editedAt = createdAt.addingTimeInterval(10) }
            messages.append(message)
        }
        return HomeMemoryHistory(messages)
    }
}
