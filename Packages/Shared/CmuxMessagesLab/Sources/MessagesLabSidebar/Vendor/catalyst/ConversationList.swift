import Foundation

// The conversation list (Messages' sidebar): one summary per conversation, as shared/MODEL.md
// "Conversation list" describes it. Platform neutral (Foundation only): catalyst compiles it
// with its Sources folder, appkit-native by path. The views live per app
// (appkit-native/Sources/Sidebar*.swift).

/// A conversation's id (the same string as the transcript model's `ID`; declared here so the
/// list's files compile without the transcript's).
typealias ConversationID = String

/// What a list row and a pinned tile show for one conversation. A value: a list owner builds
/// new summaries when its data changes and gives the list a new snapshot.
struct ConversationSummary: Codable, Hashable {
    var id: ConversationID
    /// The row's name: a contact's name, a group's name, or the participants' names joined.
    var title: String
    /// The other participants (not me), in display order.
    var participants: [SummaryParticipant]
    var avatar: AvatarSpec
    /// The newest message as the row shows it (text, or "Image", "Link: …" for other parts).
    var preview: String
    /// Name of the newest message's sender in a group (nil: me, or a 1:1 conversation).
    var previewSender: String?
    /// The newest message's time.
    var lastAt: Date
    var unreadCount: Int
    var pinned: Bool
    var muted: Bool
    /// Someone in the conversation is typing (the row and the pinned tile show the typing bubble).
    var typing: Bool
    /// The newest event is a tapback: the row shows "Lucas loved “…”" instead of the preview.
    var lastReaction: ReactionSummary?
    /// Bumped by the owner on every change (the views key their bitmaps on id and version).
    var version: Int = 0
    /// v1.2: my unsent text in this conversation's compose field (nil or empty: none). The row's
    /// preview shows "Draft: …" instead of the newest message while nobody types (to verify).
    var draft: String? = nil
    /// v1.2: my newest message was not delivered (the row shows a red exclamation mark before the
    /// time; to verify).
    var failed: Bool = false
    /// v1.2: in a group, the participants who sent the newest messages (ids from `participants`,
    /// newest first). A pinned group tile shows up to 3 of them as small avatars at its avatar's edge
    /// (to verify).
    var recentSenders: [ConversationID] = []
    /// v1.2: the conversation is with a known sender (a contact, or someone I wrote to); the
    /// list's Known / Unknown Senders filters read it.
    var knownSender: Bool = true
    /// v1.2: filtered as spam (only the Spam filter shows it).
    var spam: Bool = false
    /// v1.2: when I deleted the conversation (nil: not deleted); only Recently Deleted shows it.
    var deletedAt: Date? = nil

    var isGroup: Bool { participants.count > 1 }
    var unread: Bool { unreadCount > 0 }
    var hasDraft: Bool { !(draft ?? "").isEmpty }
}

struct SummaryParticipant: Codable, Hashable {
    var id: ConversationID
    var displayName: String
    var avatar: AvatarSpec
}

/// A circle avatar. Messages draws a contact without a photo as a grey gradient disc with
/// white initials; a group as a composite of its members' discs.
indirect enum AvatarSpec: Codable, Hashable {
    /// Initials on Messages' grey gradient (1 or 2 letters).
    case monogram(String)
    /// An image in shared/assets (or a file URL).
    case image(String)
    /// A group: up to 4 member avatars in one circle.
    case group([AvatarSpec])
    /// A group with its own picture or emoji (Messages' group photo); drawn on the grey disc.
    case emoji(String)
}

/// The newest tapback in a conversation, shown as the row's preview.
struct ReactionSummary: Codable, Hashable {
    /// The reacting participant's first name; nil when I reacted.
    var senderName: String?
    /// A tapback name (`love`, `like`, `dislike`, `laugh`, `emphasize`, `question`) or an emoji.
    var kind: String
    /// The text of the message reacted to (shortened by the view).
    var target: String
}

/// v1.2: the list's filter (Messages' View > filter menu; items and their place UNVERIFIED).
enum SidebarFilter: String, CaseIterable, Codable {
    case all, knownSenders, unknownSenders, unread, spam, recentlyDeleted
    /// Spam and deleted conversations show only under their own filters.
    func includes(_ c: ConversationSummary) -> Bool {
        let listed = !c.spam && c.deletedAt == nil
        switch self {
        case .all: return listed
        case .knownSenders: return listed && c.knownSender
        case .unknownSenders: return listed && !c.knownSender
        case .unread: return listed && c.unread
        case .spam: return c.spam && c.deletedAt == nil
        case .recentlyDeleted: return c.deletedAt != nil
        }
    }
}

/// An immutable list: the summaries newest first plus the pinned order. Read off the main
/// thread by search; values only.
struct ConversationListSnapshot {
    /// Every conversation, newest first (pinned ones included; the list skips them).
    var items: [ConversationSummary]
    /// Pinned conversation ids in tile order.
    var pinned: [ConversationID]

    init(items: [ConversationSummary], pinned: [ConversationID]) {
        self.items = items
        self.pinned = pinned
    }

    /// The unpinned rows' indices into `items`.
    func listIndices() -> [Int] {
        let p = Set(pinned)
        return items.enumerated().filter { !p.contains($0.element.id) }.map(\.offset) // cmux: no index math
    }
}

// MARK: Search

/// Case- and diacritic-insensitive search over titles, participant names and previews.
/// Keys are folded once per snapshot (off the main thread).
struct ConversationSearchIndex {
    private let keys: [String]
    init(_ s: ConversationListSnapshot) {
        keys = s.items.map { c in
            var k = c.title
            for p in c.participants { k += "\u{1}" + p.displayName }
            k += "\u{1}" + c.preview
            return ConversationSearchIndex.fold(k)
        }
    }
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
    /// Indices into the snapshot's items whose key contains every word of the query, in
    /// item order. `cancelled` is polled every 512 items.
    func matches(_ query: String, cancelled: () -> Bool = { false }) -> [Int]? {
        let words = ConversationSearchIndex.fold(query).split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return Array(keys.indices) }
        var out: [Int] = []
        for (i, k) in keys.enumerated() {
            if i & 511 == 0, cancelled() { return nil }
            if words.allSatisfy({ k.contains($0) }) { out.append(i) }
        }
        return out
    }
}

// MARK: Time label

/// Messages' row time: the time today, "Yesterday", the weekday within the last week, else
/// the short date. Localized by the formatters; cached per day and minute.
final class ConversationTimeFormatter {
    private let calendar: Calendar
    private let time = DateFormatter()
    private let weekday = DateFormatter()
    private let date = DateFormatter()
    private let yesterday: String
    init(locale: Locale = .current, yesterday: String) {
        var c = Calendar.current
        c.locale = locale
        calendar = c
        self.yesterday = yesterday
        time.locale = locale; time.dateStyle = .none; time.timeStyle = .short
        weekday.locale = locale; weekday.setLocalizedDateFormatFromTemplate("EEEE")
        date.locale = locale; date.dateStyle = .short; date.timeStyle = .none
    }
    func string(_ d: Date, now: Date = Date()) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: d)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return time.string(from: d) }
        if days == 1 { return yesterday }
        if days < 7 { return weekday.string(from: d) }
        return date.string(from: d)
    }
}

// MARK: Fixture

/// Deterministic fake conversations (fake names only) for the sidebar, its self-test and
/// benches: `make(count:)` builds `count` conversations, newest first, from `seed`.
enum ConversationListFixture {
    struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(truncatingIfNeeded: next() % UInt64(clamping: max(1, n))) } // cmux: the remainder is < n, so it fits
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
        mutating func pick<T>(_ a: [T]) -> T { a[checked: int(a.count)] ?? a[0] } // cmux: int(n) < n; an empty array still traps at a[0] (the fixture lists are literals)
    }

    static let firstNames = ["Lucas", "Maya", "Noah", "Ava", "Ethan", "Zoe", "Oliver", "Priya", "Mateo", "Hana",
                             "Leo", "Iris", "Felix", "Nora", "Kai", "Sofia", "Theo", "Amara", "Jonah", "Elena",
                             "Ruben", "Mila", "Silas", "Yuki", "Owen", "Clara", "Arjun", "Lena", "Hugo", "Talia",
                             "Marcus", "Ines", "Dev", "Freya", "Omar", "Ruth", "Emil", "Sana", "Victor", "June"]
    static let lastNames = ["Alvarez", "Brooks", "Chen", "Dalton", "Ellison", "Fischer", "Garcia", "Hayes", "Ito",
                            "Jensen", "Kowalski", "Lindqvist", "Moreau", "Nakamura", "Okafor", "Patel", "Quinn",
                            "Rossi", "Sato", "Thorne", "Usman", "Vega", "Whitlock", "Xu", "Yilmaz", "Zimmer"]
    static let groupNames = ["Climbing Crew", "Book Club", "Family", "Roommates", "Saturday Soccer", "Trip to Kyoto",
                             "Design Review", "Dinner Thursday", "Band Practice", "Garden Club", "Launch Team",
                             "Cousins", "Run Club", "Wedding Planning", "Board Games"]
    static let groupEmoji = ["🧗", "📚", "🏠", "⚽️", "🗾", "🎸", "🌱", "🚀", "🏃", "💍", "🎲"]
    static let lines = [
        "Running 10 min late, save me a seat",
        "Did you see the photos from Saturday? The light at the lake was unreal",
        "Sounds good!",
        "Can you send me the address again?",
        "Haha that's exactly what I said",
        "I'll pick up groceries on the way home. Need anything?",
        "Meeting moved to 3:30, same room",
        "Thanks so much, this is perfect",
        "Are we still on for dinner tomorrow night or should we push to Friday?",
        "Just landed ✈️",
        "Who's bringing the speaker?",
        "Ok I booked the table for 7",
        "Happy birthday!! 🎉 Hope it's a great one",
        "The draft is in the shared folder, comments welcome before Monday",
        "lol",
        "On my way",
        "Can we talk later today? Nothing urgent",
        "That trail was harder than the guide made it sound but the view at the top made up for it",
        "Love it",
        "Here's the link I mentioned",
        "Let me check my calendar and get back to you",
        "Tickets are sold out 😩",
        "Good morning! Coffee at 9?",
        "I think we should take the earlier train, the later one always fills up",
    ]
    static let attachments = ["Image", "2 Images", "Video", "Audio Message", "Link: example.com", "Location"]

    /// `count` conversations, newest first. The first `pinned` (at most 9) are pinned; ids are
    /// `conv-N`. `lead` replaces conversation 0 (the app's own transcript, e.g. Instinct).
    static func make(count: Int, seed: UInt64 = 0x5EED, now: Date = Date(), pinned: Int = 6,
                     lead: ConversationSummary? = nil) -> ConversationListSnapshot {
        var r = RNG(s: seed)
        var items: [ConversationSummary] = []
        items.reserveCapacity(count)
        var t = now.addingTimeInterval(-Double(r.int(600)))
        for i in 0..<count {
            if i == 0, let lead { items.append(lead); continue }
            // Gaps grow down the list: minutes at the top, days further down.
            let spread = i < 12 ? 2_400.0 : i < 60 ? 14_000 : 90_000
            t = t.addingTimeInterval(-Double(r.int(Int(exactly: spread) ?? 0)) - 30) // cmux: spread is an integer literal
            items.append(conversation(i, &r, at: t))
        }
        var pins: [ConversationID] = []
        // Pins: a mix of recent ones (unread, typing) and older ones.
        var i = 1
        while pins.count < min(9, pinned), i < items.count {
            // cmux: i < items.count (loop condition); the checked index keeps it explicit.
            if i % 3 != 2 || pins.count >= min(9, pinned) - 2, let slot = items.checkedIndex(i) { items[slot].pinned = true; pins.append(items[slot].id) }
            i += 1
        }
        // Pinned tiles show unread and typing as Messages does: one of each among the pins.
        if pins.count >= 3, let a = items.firstIndex(where: { $0.id == pins[1] }), let b = items.firstIndex(where: { $0.id == pins[2] }) {
            items[a].unreadCount = max(1, items[a].unreadCount) // crash-allow: (cmux) a and b come from firstIndex on items
            items[a].lastReaction = nil // crash-allow: (cmux) firstIndex
            items[b].typing = true // crash-allow: (cmux) firstIndex
        }
        return ConversationListSnapshot(items: items, pinned: pins)
    }

    /// The state gallery (`--sidebar-states`, the sidebar self-test's "states" step and
    /// appkit-native/SIDEBAR-PARITY.md): one conversation per list state, fixed content, times
    /// relative to `now`'s day. Ids are `state-<name>`; `states(...).pinned` holds six tiles
    /// (unread, typing, a 2-line group bubble, unread while typing, a muted group, a read tile).
    static func states(now: Date = Date(), lead: ConversationSummary? = nil) -> ConversationListSnapshot {
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        // Today's times stay before `now` (minutes back from it); older ones at fixed clock times.
        func ago(minutes m: Double) -> Date { now.addingTimeInterval(-Double(m) * 60) }
        func daysBack(_ d: Int, _ h: Int, _ m: Int) -> Date {
            (cal.date(byAdding: .day, value: -d, to: day) ?? day.addingTimeInterval(-Double(d) * 86_400))
                .addingTimeInterval(Double(h * 3600 + m * 60))
        }
        func who(_ f: String, _ l: String) -> SummaryParticipant {
            SummaryParticipant(id: "p-\(f.lowercased())-\(l.lowercased())", displayName: "\(f) \(l)",
                               avatar: .monogram(String(f.prefix(1)) + String(l.prefix(1))))
        }
        func one(_ name: String, _ p: SummaryParticipant, _ preview: String, at t: Date, unread: Int = 0, muted: Bool = false,
                 typing: Bool = false, reaction: ReactionSummary? = nil, draft: String? = nil, failed: Bool = false) -> ConversationSummary {
            ConversationSummary(id: "state-" + name, title: p.displayName, participants: [p], avatar: p.avatar, preview: preview,
                                previewSender: nil, lastAt: t, unreadCount: unread, pinned: false, muted: muted, typing: typing,
                                lastReaction: reaction, draft: draft, failed: failed)
        }
        func group(_ name: String, _ title: String?, _ ps: [SummaryParticipant], _ preview: String, sender: String?, at t: Date,
                   unread: Int = 0, muted: Bool = false, typing: Bool = false, emoji: String? = nil) -> ConversationSummary {
            let firsts = ps.map { String($0.displayName.split(separator: " ")[0]) }
            let t2 = title ?? (firsts.count <= 3 ? ListFormatter.localizedString(byJoining: firsts)
                               : firsts.prefix(2).joined(separator: ", ") + " & \(firsts.count - 2)")
            return ConversationSummary(id: "state-" + name, title: t2, participants: ps,
                                       avatar: emoji.map { .emoji($0) } ?? .group(ps.prefix(4).map(\.avatar)), preview: preview,
                                       previewSender: sender, lastAt: t, unreadCount: unread, pinned: false, muted: muted,
                                       typing: typing, lastReaction: nil)
        }
        let maya = who("Maya", "Okafor"), noah = who("Noah", "Ito"), ava = who("Ava", "Lindqvist"), ethan = who("Ethan", "Rossi")
        let zoe = who("Zoe", "Patel"), priya = who("Priya", "Hayes"), mateo = who("Mateo", "Vega"), hana = who("Hana", "Sato")
        let leo = who("Leo", "Brooks"), iris = who("Iris", "Moreau"), felix = who("Felix", "Garcia"), nora = who("Nora", "Quinn")
        let kai = who("Kai", "Fischer"), sofia = who("Sofia", "Thorne"), theo = who("Theo", "Xu"), amara = who("Amara", "Jensen")
        let jonah = who("Jonah", "Usman"), elena = who("Elena", "Whitlock"), ruben = who("Ruben", "Zimmer")
        var items: [ConversationSummary] = []
        if let lead { items.append(lead) }
        items += [
            // Pinned tiles (pin order below).
            one("pin-unread", maya, "Coffee at 9?", at: ago(minutes: 2), unread: 1),
            one("pin-typing", noah, "Sounds good!", at: ago(minutes: 4), typing: true),
            group("pin-group-unread", "Climbing Crew", [ava, ethan, zoe], "Did you see the photos from Saturday? The light at the lake was unreal",
                  sender: "Ava", at: ago(minutes: 6), unread: 3, emoji: "🧗"),
            one("pin-unread-typing", priya, "Are we still on for dinner tomorrow night?", at: ago(minutes: 8), unread: 2, typing: true),
            group("pin-muted-group", "Family", [mateo, hana, leo, iris], "Happy birthday!! 🎉", sender: "Hana", at: ago(minutes: 30), muted: true),
            one("pin-read", felix, "Thanks so much, this is perfect", at: daysBack(1, 18, 5)),
            // Rows: typing and unread first (the self-test checks the rows on the first screen).
            one("row-typing", nora, "Can you send me the address again?", at: ago(minutes: 3), typing: true),
            one("row-typing-unread", kai, "Just landed ✈️", at: ago(minutes: 5), unread: 1, typing: true),
            group("row-typing-group", nil, [sofia, theo, amara], "Who's bringing the speaker?", sender: "Theo", at: ago(minutes: 7), typing: true),
            one("row-unread-1", jonah, "Running 10 min late, save me a seat", at: ago(minutes: 9), unread: 1),
            one("row-unread-many", elena, "The draft is in the shared folder, comments welcome before Monday. Also the budget sheet moved to the team drive.",
                at: ago(minutes: 11), unread: 12),
            one("row-draft", ruben, "Ok I booked the table for 7", at: ago(minutes: 13), draft: "Can we make it 7:30 instead"),
            one("row-failed", theo, "See you at the station", at: ago(minutes: 14), failed: true),
            one("row-failed-muted", amara, "Sent the file", at: ago(minutes: 14.5), muted: true, failed: true),
            one("row-muted", zoe, "lol", at: ago(minutes: 15), muted: true),
            one("row-muted-unread", ava, "Meeting moved to 3:30, same room", at: ago(minutes: 17), unread: 2, muted: true),
            one("row-reaction-other", ethan, "Love it", at: ago(minutes: 19),
                reaction: ReactionSummary(senderName: "Ethan", kind: "love", target: "Here's the link I mentioned")),
            one("row-reaction-me", mateo, "Tickets are sold out 😩", at: ago(minutes: 21),
                reaction: ReactionSummary(senderName: nil, kind: "laugh", target: "Tickets are sold out 😩")),
            one("row-reaction-emoji", hana, "On my way", at: ago(minutes: 23),
                reaction: ReactionSummary(senderName: "Hana", kind: "🔥", target: "On my way")),
            one("row-attachment-image", leo, "Image", at: ago(minutes: 25)),
            one("row-attachment-images", iris, "2 Images", at: ago(minutes: 27)),
            one("row-attachment-audio", felix, "Audio Message", at: ago(minutes: 29)),
            one("row-link", nora, "Link: example.com", at: ago(minutes: 31)),
            group("row-group-named", "Design Review", [kai, sofia, theo, amara, jonah], "Let me check my calendar and get back to you",
                  sender: "Sofia", at: ago(minutes: 33)),
            group("row-group-two", nil, [elena, ruben], "Good morning, coffee at 9?", sender: nil, at: ago(minutes: 35)),
            one("row-long-name", who("Bartholomew-Alexander", "Montgomery-Fitzwilliam"), "Sounds good!", at: ago(minutes: 37)),
            one("row-emoji-only", zoe, "🎉🎉🎉", at: ago(minutes: 39)),
            one("row-yesterday", priya, "I'll pick up groceries on the way home. Need anything?", at: daysBack(1, 20, 12)),
            one("row-weekday", mateo, "That trail was harder than the guide made it sound but the view at the top made up for it", at: daysBack(3, 9, 30)),
            one("row-date", hana, "Can we talk later today? Nothing urgent", at: daysBack(12, 14, 0)),
        ]
        // Newest first, as a snapshot is (lead first when it is newest).
        items.sort { $0.lastAt > $1.lastAt }
        // Spam and a recently deleted conversation (their filters; All leaves them out).
        items.append(ConversationSummary(id: "state-spam", title: "+1 (555) 010-4477", participants: [who("Unknown", "Sender")],
                                         avatar: .monogram(""), preview: "Your package is waiting, confirm your address at the link",
                                         previewSender: nil, lastAt: ago(minutes: 1), unreadCount: 0, pinned: false, muted: false,
                                         typing: false, lastReaction: nil, knownSender: false, spam: true))
        var gone = one("deleted", ruben, "See you next week", at: daysBack(2, 11, 0))
        gone.deletedAt = daysBack(1, 9, 0)
        items.append(gone)
        items.sort { $0.lastAt > $1.lastAt }
        // Two unknown senders (the Unknown Senders filter).
        let pins = ["pin-unread", "pin-typing", "pin-group-unread", "pin-unread-typing", "pin-muted-group", "pin-read"].map { "state-" + $0 }
        // cmux: element-wise, no index math (crash ratchet)
        items = items.map { item in
            var item = item
            if ["state-row-date", "state-row-long-name"].contains(item.id) { item.knownSender = false }
            // Pinned groups show who wrote last.
            if item.id == "state-pin-group-unread" { item.recentSenders = [ava.id, zoe.id] }
            if item.id == "state-pin-muted-group" { item.recentSenders = [hana.id, mateo.id, iris.id] }
            if pins.contains(item.id) { item.pinned = true }
            return item
        }
        return ConversationListSnapshot(items: items, pinned: pins)
    }

    static func person(_ r: inout RNG) -> SummaryParticipant {
        let f = r.pick(firstNames), l = r.pick(lastNames)
        let id = "p-\(f.lowercased())-\(l.lowercased())"
        return SummaryParticipant(id: id, displayName: "\(f) \(l)", avatar: .monogram(String(f.prefix(1)) + String(l.prefix(1))))
    }

    static func conversation(_ i: Int, _ r: inout RNG, at t: Date) -> ConversationSummary {
        let group = r.chance(0.16)
        var people: [SummaryParticipant] = []
        if group {
            for _ in 0..<(2 + r.int(4)) {
                let p = person(&r)
                if !people.contains(where: { $0.id == p.id }) { people.append(p) }
            }
        } else {
            people = [person(&r)]
        }
        let named = group && r.chance(0.6)
        let title: String = {
            if !group { return people[0].displayName }
            if named { return r.pick(groupNames) }
            let firsts = people.map { String($0.displayName.split(separator: " ")[0]) }
            return firsts.count <= 3 ? ListFormatter.localizedString(byJoining: firsts) : firsts.prefix(2).joined(separator: ", ") + " & \(firsts.count - 2)"
        }()
        let avatar: AvatarSpec = group ? (named && r.chance(0.5) ? .emoji(r.pick(groupEmoji)) : .group(people.prefix(4).map(\.avatar))) : people[0].avatar
        let fromMe = r.chance(0.35)
        let preview = r.chance(0.12) ? r.pick(attachments) : r.pick(lines)
        let sender = group && !fromMe ? String(r.pick(people).displayName.split(separator: " ")[0]) : nil
        let unread = !fromMe && r.chance(i < 40 ? 0.3 : 0.06) ? 1 + r.int(4) : 0
        var reaction: ReactionSummary? = nil
        if unread == 0, r.chance(0.12) {
            let who: String? = r.chance(0.5) ? nil : String(r.pick(people).displayName.split(separator: " ")[0])
            reaction = ReactionSummary(senderName: who, kind: r.pick(["love", "like", "laugh", "emphasize", "question", "dislike", "🔥"]),
                                       target: r.pick(lines))
        }
        return ConversationSummary(id: "conv-\(i)", title: title, participants: people, avatar: avatar, preview: preview,
                                   previewSender: sender, lastAt: t, unreadCount: unread, pinned: false,
                                   muted: r.chance(0.06), typing: i > 0 && i < 30 && r.chance(0.04), lastReaction: reaction)
    }
}
