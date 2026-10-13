import Foundation

/// A participant mentioned in a message: a range of the message text, in
/// UTF-16 code units (the unit of `NSString`, `NSRange` and JavaScript
/// strings, so ranges travel unchanged between the wire and the text views).
public struct ConversationMention: Sendable, Hashable {
    public var participantID: String
    public var location: Int
    public var length: Int

    public init(participantID: String, location: Int, length: Int) {
        self.participantID = participantID
        self.location = location
        self.length = length
    }

    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public var end: Int { location + length }
}

extension ConversationParticipant {
    /// The text a mention of this participant inserts: the first name, as
    /// Messages does.
    public var mentionName: String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }
}

extension ConversationMessage {
    /// Mentions whose ranges fit the text, sorted and non-overlapping.
    public var validMentions: [ConversationMention] {
        ConversationMentionEditing.normalized(mentions, textLength: (text as NSString).length)
    }

    public func mentions(participantID: String?) -> Bool {
        guard let participantID else { return false }
        return validMentions.contains { $0.participantID == participantID }
    }
}

/// An active mention query at the caret: the text that a picked participant
/// replaces, and who matches it.
public struct ConversationMentionQuery: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// "@" followed by a (possibly empty) name prefix.
        case explicit
        /// A typed word that is exactly a participant's name. Messages grays it.
        case completedName
    }

    public var kind: Kind
    /// UTF-16 range replaced on commit (includes the "@").
    public var location: Int
    public var length: Int
    public var matches: [ConversationParticipant]

    public init(kind: Kind, location: Int, length: Int, matches: [ConversationParticipant]) {
        self.kind = kind
        self.location = location
        self.length = length
        self.matches = matches
    }

    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// Composer text plus its mentions.
public struct ConversationMentionDraft: Sendable, Hashable {
    public var text: String
    public var mentions: [ConversationMention]

    public init(text: String = "", mentions: [ConversationMention] = []) {
        self.text = text
        self.mentions = mentions
    }
}

/// Platform-independent mention editing shared by the iOS and macOS composers.
public enum ConversationMentionEditing {
    /// Drops mentions outside the text or overlapping an earlier one; sorts.
    public static func normalized(_ mentions: [ConversationMention], textLength: Int) -> [ConversationMention] {
        var result: [ConversationMention] = []
        for mention in mentions.sorted(by: { $0.location < $1.location }) {
            guard mention.location >= 0, mention.length > 0, mention.end <= textLength else { continue }
            if let last = result.last, mention.location < last.end { continue }
            result.append(mention)
        }
        return result
    }

    /// The result of a user edit: what to actually replace (a deletion that
    /// touches a mention widens to the whole mention, so tokens delete as a
    /// unit) and the draft afterwards.
    public struct EditResult: Sendable, Hashable {
        public var range: NSRange
        public var replacement: String
        public var draft: ConversationMentionDraft
        /// Caret after the edit, UTF-16.
        public var caret: Int
    }

    /// Applies "replace `range` with `replacement`". Deleting into a mention
    /// removes the whole mention; typing inside one turns it back into plain
    /// text; mentions after the edit shift.
    public static func apply(_ range: NSRange, replacement: String, to draft: ConversationMentionDraft) -> EditResult {
        let ns = draft.text as NSString
        // Clamp to the text. (NSIntersectionRange turns an empty range at the
        // end into {0, 0}, which would move a caret insertion to the start.)
        let start = min(max(0, range.location == NSNotFound ? ns.length : range.location), ns.length)
        var range = NSRange(location: start, length: min(max(0, range.length), ns.length - start))
        if replacement.isEmpty, range.length > 0 {
            // Widen to every mention the deletion touches.
            for mention in draft.mentions where mention.location < NSMaxRange(range) && mention.end > range.location {
                range = NSUnionRange(range, mention.nsRange)
            }
        }
        let inserted = (replacement as NSString).length
        let mentions = adjusted(draft.mentions, forEdit: range, replacementLength: inserted)
        let text = ns.replacingCharacters(in: range, with: replacement)
        return EditResult(
            range: range,
            replacement: replacement,
            draft: ConversationMentionDraft(text: text, mentions: normalized(mentions, textLength: (text as NSString).length)),
            caret: range.location + inserted
        )
    }

    /// Mentions after replacing `range` with `replacementLength` UTF-16
    /// units: those before stay, those after shift, any the edit touches
    /// revert to plain text. An insertion at a mention's end stays outside it.
    public static func adjusted(_ mentions: [ConversationMention], forEdit range: NSRange, replacementLength: Int) -> [ConversationMention] {
        let delta = replacementLength - range.length
        var result: [ConversationMention] = []
        for var mention in mentions {
            if mention.end <= range.location {
                result.append(mention)
            } else if mention.location >= NSMaxRange(range) {
                mention.location += delta
                result.append(mention)
            }
        }
        return result
    }

    /// The mention query ending at `caret`, if any. Only participants other
    /// than me can be mentioned.
    public static func query(in draft: ConversationMentionDraft, caret: Int, participants: [ConversationParticipant]) -> ConversationMentionQuery? {
        let ns = draft.text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let candidates = participants.filter { !$0.isMe }
        guard !candidates.isEmpty else { return nil }
        if draft.mentions.contains(where: { $0.location < caret && $0.end >= caret }) { return nil }
        let whitespace = CharacterSet.whitespacesAndNewlines

        func isSpace(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
            return whitespace.contains(scalar)
        }
        func wordStart(before end: Int) -> Int {
            var start = end
            while start > 0, !isSpace(start - 1) { start -= 1 }
            return start
        }
        func overlapsMention(_ start: Int, _ end: Int) -> Bool {
            draft.mentions.contains { $0.location < end && $0.end > start }
        }

        // "@prefix" with the caret at its end.
        let start = wordStart(before: caret)
        if start < caret, ns.character(at: start) == 0x40, !overlapsMention(start, caret) {
            let prefix = ns.substring(with: NSRange(location: start + 1, length: caret - start - 1))
            let matches = candidates.filter { matchesPrefix($0, prefix) }
            guard !matches.isEmpty else { return nil }
            return ConversationMentionQuery(kind: .explicit, location: start, length: caret - start, matches: matches)
        }

        // A completed name: the word (or "First Last") ending at the caret,
        // or just before one trailing space.
        var end = caret
        if end > 0, isSpace(end - 1), !(end > 1 && isSpace(end - 2)), ns.character(at: end - 1) == 0x20 { end -= 1 }
        guard end > 0, !isSpace(end - 1) else { return nil }
        let lastStart = wordStart(before: end)
        var spans = [lastStart]
        if lastStart > 1, ns.character(at: lastStart - 1) == 0x20, !isSpace(lastStart - 2) {
            spans.insert(wordStart(before: lastStart - 1), at: 0)
        }
        for spanStart in spans where !overlapsMention(spanStart, end) {
            let word = ns.substring(with: NSRange(location: spanStart, length: end - spanStart))
            let matches = candidates.filter { matchesName($0, word) }
            if !matches.isEmpty {
                return ConversationMentionQuery(kind: .completedName, location: spanStart, length: end - spanStart, matches: matches)
            }
        }
        return nil
    }

    /// Replaces the query's text with the participant's mention name and a
    /// following space (unless one is already there).
    public static func commit(_ query: ConversationMentionQuery, participant: ConversationParticipant, in draft: ConversationMentionDraft) -> EditResult {
        let ns = draft.text as NSString
        let afterIndex = query.location + query.length
        let hasSpaceAfter = afterIndex < ns.length && ns.character(at: afterIndex) == 0x20
        let name = participant.mentionName
        let replacement = hasSpaceAfter ? name : name + " "
        var result = apply(query.nsRange, replacement: replacement, to: draft)
        let mention = ConversationMention(participantID: participant.id, location: query.location, length: (name as NSString).length)
        result.draft.mentions = normalized(result.draft.mentions + [mention], textLength: (result.draft.text as NSString).length)
        result.caret = query.location + (name as NSString).length + 1
        return result
    }

    /// Shifts mentions for text whose leading `removedPrefix` UTF-16 units
    /// were trimmed and whose length is now `textLength`.
    public static func trimmed(_ mentions: [ConversationMention], removedPrefix: Int, textLength: Int) -> [ConversationMention] {
        normalized(mentions.map {
            ConversationMention(participantID: $0.participantID, location: $0.location - removedPrefix, length: $0.length)
        }, textLength: textLength)
    }

    /// Mentions that still name their participant after the text changed.
    public static func surviving(_ mentions: [ConversationMention], oldText: String, newText: String) -> [ConversationMention] {
        let old = oldText as NSString
        let new = newText as NSString
        return normalized(mentions, textLength: new.length).filter { mention in
            mention.end <= old.length && old.substring(with: mention.nsRange) == new.substring(with: mention.nsRange)
        }
    }

    private static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func nameParts(_ participant: ConversationParticipant) -> [String] {
        participant.name.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matchesPrefix(_ participant: ConversationParticipant, _ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        if participant.name.range(of: prefix, options: compareOptions.union(.anchored)) != nil { return true }
        return nameParts(participant).contains { $0.range(of: prefix, options: compareOptions.union(.anchored)) != nil }
    }

    static func matchesName(_ participant: ConversationParticipant, _ word: String) -> Bool {
        if participant.name.compare(word, options: compareOptions) == .orderedSame { return true }
        return nameParts(participant).contains { $0.compare(word, options: compareOptions) == .orderedSame }
    }
}
