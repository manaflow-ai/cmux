import Foundation

/// Demo data for the mock owner: one Chief pinned at the top, two subchiefs,
/// three people, two groups and one invited person. The Chief's history is
/// generated from its seq on read, so a long history costs no memory.
enum MockHomeSeed {
    struct Seed {
        var me: Participant
        var chief: Participant
        var people: [Participant]
        var conversations: [ConversationSummary]
        var messages: [ConversationID: [Message]]
        var generated: [ConversationID: Seq]
        var members: [ContactAddress: ParticipantID]
    }

    static func make(now: Date, chiefHistory: Int) -> Seed {
        let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Lawrence")
        let chief = Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief",
                                agentClass: .chief, ownerUser: me.id)
        let release = Participant(id: ParticipantID("agent_release"), kind: .agent, displayName: "Release Chief",
                                  agentClass: .chief, ownerUser: me.id)
        let infra = Participant(id: ParticipantID("agent_infra"), kind: .agent, displayName: "Infra Chief",
                                agentClass: .chief, ownerUser: me.id)
        let austin = Participant(id: ParticipantID("user_austin"), kind: .human, displayName: "Austin")
        let aziz = Participant(id: ParticipantID("user_aziz"), kind: .human, displayName: "Aziz")
        let leo = Participant(id: ParticipantID("user_leo"), kind: .human, displayName: "Leo")
        let invited = Participant(id: ParticipantID("user_inv_sam"), kind: .human, displayName: "sam@example.com",
                                  membership: .invited, invitedContact: "sam@example.com")

        var conversations: [ConversationSummary] = []
        var messages: [ConversationID: [Message]] = [:]
        var generated: [ConversationID: Seq] = [:]

        // The Chief: pinned first, with a long generated history.
        let chiefID = ConversationID("conv_chief")
        let total = Seq(max(chiefHistory, 1))
        var chiefSummary = ConversationSummary(
            id: chiefID, participants: [me, chief], lastSeq: total, rev: total,
            createdAt: now.addingTimeInterval(-86_400 * 90), updatedAt: now.addingTimeInterval(-60),
            readCursors: [me.id: total - min(total, 2)], pinRank: 0
        )
        chiefSummary.lastMessage = generatedMessage(seq: total, total: total, in: chiefSummary, epoch: now)
        conversations.append(chiefSummary)
        generated[chiefID] = total

        func add(_ id: String, title: String = "", _ participants: [Participant], minutesAgo: Double,
                 unread: Int = 0, _ lines: [(Participant, String)]) {
            let conversation = ConversationID(id)
            let start = now.addingTimeInterval(-minutesAgo * 60)
            var list: [Message] = []
            for (index, line) in lines.enumerated() {
                list.append(Message(
                    id: MessageID("msg_\(id)_\(index + 1)"), conversation: conversation, seq: Seq(index + 1),
                    clientMessageID: IdempotencyKey("seed_\(id)_\(index + 1)"), author: line.0.id,
                    parts: [.text(line.1)],
                    createdAt: start.addingTimeInterval(Double(index - lines.count) * 90)
                ))
            }
            let last = Seq(list.count)
            messages[conversation] = list
            conversations.append(ConversationSummary(
                id: conversation, title: title, participants: participants, lastSeq: last, rev: last,
                createdAt: start.addingTimeInterval(-86_400), updatedAt: list.last?.createdAt ?? start,
                lastMessage: list.last, readCursors: [me.id: last - Seq(min(unread, Int(last)))]
            ))
        }

        add("conv_release", [me, release], minutesAgo: 12, unread: 1, [
            (me, "Cut the nightly once the iOS shell builds on the fleet."),
            (release, "Queued. The macOS compile is green; waiting on the iOS archive."),
            (release, "Nightly 2026-10-02 is out. Release notes are drafted for your review."),
        ])
        add("conv_infra", [me, infra], minutesAgo: 95, [
            (me, "How full are the fleet disks?"),
            (infra, "Lowest is 41% free. No worker is below the floor."),
        ])
        add("conv_austin", [me, austin], minutesAgo: 30, unread: 2, [
            (austin, "Did the transport lane pick Freestyle tunnels?"),
            (me, "Yes, with the relay as the fallback."),
            (austin, "Nice. Can I try the iPhone build tonight?"),
            (austin, "Also: the invite flow should accept phone numbers."),
        ])
        add("conv_aziz", [me, aziz], minutesAgo: 240, [
            (aziz, "Phone is plugged in and unlocked for the next install."),
            (me, "Thanks!"),
        ])
        add("conv_core", title: "cmux core", [me, austin, leo, chief], minutesAgo: 50, unread: 3, [
            (leo, "Agent mail envelope is ready for review."),
            (austin, "@Chief can you summarize the open PRs?"),
            (chief, "Seven open: three iOS, two transport, two Home backend. None is blocked."),
            (leo, "Ship it."),
        ])
        add("conv_launch", title: "Launch", [me, aziz, leo], minutesAgo: 600, [
            (aziz, "Screenshots for the App Store are in the shared folder."),
            (leo, "I'll draft the post."),
        ])
        add("conv_sam", [me, invited], minutesAgo: 1_400, [
            (me, "Hey Sam, I'm using cmux to run my coding agents from my phone. Join me here."),
        ])

        var members: [ContactAddress: ParticipantID] = [:]
        members[.email("austin@manaflow.com")] = austin.id
        members[.email("aziz@manaflow.com")] = aziz.id
        members[.email("leo@manaflow.com")] = leo.id
        members[.email("sam@example.com")] = invited.id

        return Seed(me: me, chief: chief, people: [chief, release, infra, austin, aziz, leo, invited],
                    conversations: conversations, messages: messages, generated: generated, members: members)
    }

    private static let chiefLines = [
        "Started three agents on the transport branch.",
        "The fleet build finished in 4 minutes 12 seconds.",
        "Two tests failed on the base branch; they are not ours.",
        "I opened a draft PR with the plan. Want me to request review?",
        "Summary: the shell builds, sign-in works, Home renders from the mock source.",
        "The Mac is asleep; I will continue on the team VM.",
        "Lawrence asked for variants. I prepared two list densities.",
        "Done. The device install passed the auth gate.",
    ]

    private static let myLines = [
        "Status?",
        "Run the focused tests on CI.",
        "Looks good. Keep going.",
        "What is blocking the iOS archive?",
        "Ship the nightly after the checks pass.",
    ]

    static func generatedMessage(seq: Seq, total: Seq, in summary: ConversationSummary, epoch: Date) -> Message {
        let me = summary.participants[0]
        let chief = summary.participants[1]
        // Mostly Chief messages, with my messages every few seqs.
        let mine = seq % 4 == 1
        let lines = mine ? myLines : chiefLines
        let text = lines[Int(seq % Seq(lines.count))]
        let age = Double(total - seq) * 47 + 60
        return Message(
            id: MessageID("msg_gen_\(seq)"), conversation: summary.id, seq: seq,
            clientMessageID: IdempotencyKey("gen_\(seq)"), author: mine ? me.id : chief.id,
            parts: [.text(text)], createdAt: epoch.addingTimeInterval(-age)
        )
    }

    static func chiefGreeting(_ name: String) -> String {
        "Hi, I'm \(name). Tell me what to work on, and I'll run agents for it."
    }

    static func reply(index: Int) -> String {
        chiefLines[index % chiefLines.count]
    }
}
