import Foundation

// Emoji by shortcode in the agent chat composer, the same lifecycle as the Mac's composer
// (webviews/src/agent-session/acpmux/emojiShortcodes.ts). Leo, 2026-11-22: "for some reason i
// can't do :pleading_face: with the emoji here. we need to actually improve the ergonomics and
// lifecycle of that." Typing `:` and two letters at a word start lists the emoji whose GitHub
// shortcode matches; the closing `:` of a known `:code:` writes it at once; a pasted `:code:`
// becomes its emoji; a toneable emoji comes in the person's remembered skin tone. Everything here
// is pure (text and UTF-16 offsets in, edits out), so the field (ChatComposerField) only applies
// the edits and the tests cover every rule.
//
// The table is generated from the icon picker's (cmux-next-ios/scripts/gen-emoji-shortcodes.py:
// Unicode emoji-test.txt and CLDR annotations, Unicode License v3; emojibase-data GitHub
// shortcodes, MIT) and read the first time a trigger is typed, never at launch.

/// One emoji that has a GitHub shortcode.
public struct EmojiShortcodeRecord: Sendable, Hashable {
    /// Position in the table: the default order.
    public let index: Int
    /// The base (untoned) glyph.
    public let emoji: String
    /// Shortcodes without colons, the shown one first (`+1`, `thumbsup`).
    public let codes: [String]
    /// The CLDR English name.
    public let name: String
    /// The five uniform skin-tone forms, light to dark; empty when the emoji takes no tone.
    public let tones: [String]
    /// Lower-cased names, codes, keywords and their words, each after a "\n".
    let search: String

    /// The glyph in `tone` (1...5, light to dark); the base glyph for 0 or an emoji with no tones.
    public func glyph(tone: Int) -> String {
        (1...5).contains(tone) && tones.count == 5 ? tones[tone - 1] : emoji
    }
}

/// The bundled shortcode table.
public final class EmojiShortcodeTable: Sendable {
    public let records: [EmojiShortcodeRecord]
    private let byCode: [String: Int]
    /// Every glyph, base and toned, to its record.
    private let byGlyph: [String: Int]

    /// Parses the generated table: one emoji per line, tab-separated glyph, codes (`|`), name,
    /// keywords (`|`), tone forms (space-separated); `#` lines are comments.
    public init(tsv: String) {
        var records: [EmojiShortcodeRecord] = []
        var byCode: [String: Int] = [:]
        var byGlyph: [String: Int] = [:]
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { continue }
            let codes = fields[1].split(separator: "|").map(String.init)
            guard !codes.isEmpty else { continue }
            let tones = fields.count > 4 ? fields[4].split(separator: " ").map(String.init) : []
            let index = records.count
            var words = Set<String>()
            let name = fields[2]
            for phrase in [name] + fields[3].split(separator: "|").map(String.init) + codes {
                let folded = phrase.lowercased()
                words.insert(folded)
                for word in folded.split(whereSeparator: { " _-:,.!?()'\"".contains($0) }) { words.insert(String(word)) }
            }
            records.append(EmojiShortcodeRecord(index: index, emoji: fields[0], codes: codes, name: name, tones: tones,
                                                search: "\n" + words.sorted().joined(separator: "\n")))
            for code in codes where byCode[code] == nil { byCode[code] = index }
            for glyph in [fields[0]] + tones where byGlyph[glyph] == nil { byGlyph[glyph] = index }
        }
        self.records = records
        self.byCode = byCode
        self.byGlyph = byGlyph
    }

    /// The record a shortcode or alias names (lower case, no colons).
    public func record(code: String) -> EmojiShortcodeRecord? { byCode[code].map { records[$0] } }

    /// The record of a glyph, base or toned.
    public func record(glyph: String) -> EmojiShortcodeRecord? { byGlyph[glyph].map { records[$0] } }

    /// The bundled table, read on first use (the first trigger typed), never at launch.
    public static let bundled: EmojiShortcodeTable = {
        guard let url = Bundle.module.url(forResource: "emoji-shortcodes", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return EmojiShortcodeTable(tsv: "") }
        return EmojiShortcodeTable(tsv: text)
    }()
}

/// What the caret ends: a `:shortcode` being typed, or a whole text emoticon.
public struct EmojiTrigger: Equatable, Sendable {
    /// The typed token's UTF-16 range in the text (what accepting a row replaces).
    public let range: NSRange
    /// The token as typed (`:plead`, `:)`, `<3`).
    public let token: String
    /// The shortcode letters after `:`, lower case; nil for an emoticon that is not one.
    public let query: String?
    /// The token is a text emoticon (`:)`, `<3`).
    public let emoticon: Bool
}

/// One row of the list.
public struct EmojiMatch: Equatable, Sendable, Identifiable {
    public var id: String { emoji }
    /// The base glyph (the row writes it in the remembered tone).
    public let emoji: String
    /// The shortcode shown, without colons: the one that matched.
    public let code: String
    /// The UTF-16 range in `code` of the letters the query matched (bold); empty when none did.
    public let matched: NSRange
}

/// An edit for the field to apply: replace `range` (UTF-16) with `replacement`, caret at `caret`.
public struct EmojiEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let caret: Int
    /// A Slack-style `::skin-tone-N:` named a tone: remember it (0...5).
    public var rememberTone: Int?
    /// The emoji picked (base glyph), for recents.
    public var picked: String?
}

/// Recent picks (frecency) and the remembered skin tone, as the icon picker keeps them
/// (webviews/src/icon-picker/recents.ts).
public struct EmojiPrefs: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var key: String
        public var count: Int
        /// Seconds since 1970 of the last use.
        public var last: TimeInterval
    }

    /// 0 (none) or 1...5, light to dark.
    public var tone: Int = 0
    public var recents: [Entry] = []

    public static let maxRecents = 36
    static let halfLife: TimeInterval = 7 * 24 * 3600

    public init(tone: Int = 0, recents: [Entry] = []) {
        self.tone = tone
        self.recents = recents
    }

    /// Use count decayed by age: one use today outranks three a month ago.
    static func frecency(_ entry: Entry, now: TimeInterval) -> Double {
        Double(entry.count) * pow(0.5, max(0, now - entry.last) / halfLife)
    }

    public func recording(_ emoji: String, now: TimeInterval) -> EmojiPrefs {
        let count = (recents.first { $0.key == emoji }?.count ?? 0) + 1
        var next = self
        next.recents = ([Entry(key: emoji, count: count, last: now)] + recents.filter { $0.key != emoji })
            .sorted { Self.frecency($0, now: now) > Self.frecency($1, now: now) }
            .prefix(Self.maxRecents).map { $0 }
        return next
    }

    /// A search tie-breaker per glyph: at most 9, under one match tier (10).
    func boost(now: TimeInterval) -> [String: Int] {
        let ranked = recents.sorted { Self.frecency($0, now: now) > Self.frecency($1, now: now) }
        var boost: [String: Int] = [:]
        for (rank, entry) in ranked.enumerated() { boost[entry.key] = max(1, 9 - rank) }
        return boost
    }
}

public enum EmojiShortcodes {
    /// How many rows the list shows at most.
    public static let shown = 6
    /// Letters after `:` before the list opens (one letter matches half the table).
    public static let minQuery = 2

    /// Characters a token may follow besides whitespace and a line start.
    static let openers: Set<Character> = ["(", "[", "{", "\"", "'"]

    /// Text emoticons and the shortcodes they mean, best first (the Mac's `EMOTICONS`).
    public static let emoticons: [String: [String]] = [
        ":)": ["slightly_smiling_face", "smiley", "blush"],
        ":-)": ["slightly_smiling_face", "smiley", "blush"],
        "(:": ["slightly_smiling_face", "smiley"],
        ":(": ["slightly_frowning_face", "disappointed", "cry"],
        ":-(": ["slightly_frowning_face", "disappointed", "cry"],
        ":D": ["smiley", "smile", "grin"],
        ":-D": ["smiley", "smile", "grin"],
        ":DD": ["laughing", "joy", "rofl"],
        ":DDD": ["joy", "rofl", "laughing"],
        "XD": ["laughing", "joy", "rofl"],
        "xD": ["laughing", "joy", "rofl"],
        ";)": ["wink", "stuck_out_tongue_winking_eye"],
        ";-)": ["wink", "stuck_out_tongue_winking_eye"],
        ":P": ["stuck_out_tongue", "stuck_out_tongue_winking_eye", "stuck_out_tongue_closed_eyes"],
        ":p": ["stuck_out_tongue", "stuck_out_tongue_winking_eye", "stuck_out_tongue_closed_eyes"],
        ":-P": ["stuck_out_tongue", "stuck_out_tongue_winking_eye"],
        ";P": ["stuck_out_tongue_winking_eye", "stuck_out_tongue"],
        ";p": ["stuck_out_tongue_winking_eye", "stuck_out_tongue"],
        ":O": ["open_mouth", "astonished"],
        ":o": ["open_mouth", "astonished"],
        ":'(": ["cry", "sob"],
        ":|": ["neutral_face", "expressionless"],
        ":/": ["confused"],
        ":*": ["kissing_heart"],
        "<3": ["heart", "sparkling_heart", "two_hearts"],
        "</3": ["broken_heart"],
        "B)": ["sunglasses"],
        "8)": ["sunglasses"],
        ">:(": ["angry", "rage"],
        "^^": ["blush", "smile"],
        "^_^": ["blush", "smile"],
        "-_-": ["expressionless"],
    ]

    static func isCodeCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "+" || c == "-")
    }

    // MARK: Trigger

    /// The token the caret ends on its line: what follows the last whitespace (and one opener
    /// before a `:`), with its UTF-16 start.
    static func token(in text: NSString, caret: Int) -> (token: String, start: Int)? {
        guard caret > 0, caret <= text.length else { return nil }
        let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                          range: NSRange(location: 0, length: caret))
        let start = space.location == NSNotFound ? 0 : NSMaxRange(space)
        guard start < caret else { return nil }
        return (text.substring(with: NSRange(location: start, length: caret - start)), start)
    }

    /// The trigger the caret ends in `text` (UTF-16 `caret`), or nil. A token starts a word, so a
    /// time (`10:30`), a URL (`https://`) or `key:value` never opens the list; neither does code.
    public static func trigger(in text: String, caret: Int) -> EmojiTrigger? {
        let ns = text as NSString
        guard let found = Self.token(in: ns, caret: caret) else { return nil }
        var (token, start) = (found.token, found.start)
        if emoticons[token] == nil, let first = token.first, openers.contains(first), token.dropFirst().first == ":" {
            token.removeFirst()
            start += 1
        }
        let emoticon = emoticons[token] != nil
        var query: String?
        if token.hasPrefix(":") {
            let letters = token.dropFirst()
            if letters.count >= minQuery, letters.allSatisfy(isCodeCharacter) { query = letters.lowercased() }
        }
        guard emoticon || query != nil, !inCode(ns, at: start) else { return nil }
        return EmojiTrigger(range: NSRange(location: start, length: caret - start), token: token, query: query, emoticon: emoticon)
    }

    /// True when UTF-16 `at` is inside a fenced code block or an inline code span.
    public static func inCode(_ text: NSString, at: Int) -> Bool {
        let before = text.substring(to: min(at, text.length))
        var fences = 0
        var lineStart = before.startIndex
        for line in before.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix(while: { $0 == " " })
            if indent.count <= 3, line.dropFirst(indent.count).hasPrefix("```") || line.dropFirst(indent.count).hasPrefix("~~~") {
                fences += 1
            }
            lineStart = line.startIndex
        }
        if fences % 2 == 1 { return true }
        return before[lineStart...].filter { $0 == "`" }.count % 2 == 1
    }

    // MARK: Rows

    /// Where `query` starts a word of `code` (its start, or after `_`, `-`, `+`); nil if nowhere.
    static func wordStart(_ code: String, _ query: String) -> Int? {
        let c = Array(code.utf16), q = Array(query.utf16)
        guard q.count <= c.count else { return nil }
        for at in 0...(c.count - q.count) where Array(c[at..<at + q.count]) == q {
            if at == 0 || [UInt16(95), 45, 43].contains(c[at - 1]) { return at }
        }
        return nil
    }

    /// `query`'s letters in order inside `code`, the first letter first (`thup` in `thumbsup`).
    static func isSubsequence(_ query: String, of code: String) -> Bool {
        guard let first = query.first, code.first == first else { return false }
        var rest = query.dropFirst()[...]
        for c in code.dropFirst() where c == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }

    /// The rows for `trigger`: an emoticon's faces first, then shortcodes ranked exact, prefix of
    /// the shown code, a word of it, an alias, a CLDR name or keyword word, then a fuzzy
    /// subsequence (`:thup`); a recent pick ranks up about one tier, never over an exact code.
    /// Ties: the shorter code, then table order. One row per glyph.
    public static func matches(_ trigger: EmojiTrigger, in table: EmojiShortcodeTable, prefs: EmojiPrefs = EmojiPrefs(),
                               now: TimeInterval = Date().timeIntervalSince1970, limit: Int = shown) -> [EmojiMatch] {
        var out: [EmojiMatch] = []
        var seen = Set<String>()
        func push(_ match: EmojiMatch) {
            guard out.count < limit, seen.insert(match.emoji).inserted else { return }
            out.append(match)
        }
        if trigger.emoticon {
            for code in emoticons[trigger.token] ?? [] {
                if let record = table.record(code: code) {
                    push(EmojiMatch(emoji: record.emoji, code: record.codes[0], matched: NSRange(location: 0, length: 0)))
                }
            }
        }
        guard let query = trigger.query else { return out }
        let boost = prefs.boost(now: now)
        let needle = "\n" + query
        var scored: [(score: Int, length: Int, index: Int, match: EmojiMatch)] = []
        for record in table.records {
            let primary = record.codes[0]
            let aliases = record.codes.dropFirst()
            var tier = -1
            var code = primary
            var at: Int? = 0
            if primary == query {
                tier = 0
            } else if primary.hasPrefix(query) {
                tier = 1
            } else if let word = wordStart(primary, query) {
                tier = 2
                at = word
            } else if let alias = aliases.first(where: { wordStart($0, query) != nil }) {
                tier = 3
                code = alias
                at = wordStart(alias, query)
            } else if record.search.contains(needle) {
                tier = 4
                at = nil
            } else if let fuzzy = record.codes.first(where: { isSubsequence(query, of: $0) }) {
                tier = 5
                code = fuzzy
                at = nil
            }
            guard tier >= 0 else { continue }
            let bonus = tier == 0 ? 0 : (boost[record.emoji] ?? 0)
            let matched = at.map { NSRange(location: $0, length: query.utf16.count) } ?? NSRange(location: 0, length: 0)
            scored.append((tier * 10 - bonus, code.utf16.count, record.index, EmojiMatch(emoji: record.emoji, code: code, matched: matched)))
        }
        scored.sort { ($0.score, $0.length, $0.index) < ($1.score, $1.length, $1.index) }
        for entry in scored {
            if out.count >= limit { break }
            push(entry.match)
        }
        return out
    }

    // MARK: Edits

    /// Accepting `match` for `trigger`: the glyph in the remembered tone and one space (none when
    /// a space already follows), the caret after the space.
    public static func accept(_ match: EmojiMatch, for trigger: EmojiTrigger, in text: String, table: EmojiShortcodeTable,
                              tone: Int) -> EmojiEdit {
        let ns = text as NSString
        let glyph = table.record(glyph: match.emoji)?.glyph(tone: tone) ?? match.emoji
        let after = NSMaxRange(trigger.range)
        let spaceFollows = after < ns.length && ns.character(at: after) == 0x20
        let replacement = spaceFollows ? glyph : glyph + " "
        let caret = trigger.range.location + replacement.utf16.count + (spaceFollows ? 1 : 0)
        return EmojiEdit(range: trigger.range, replacement: replacement, caret: caret, picked: match.emoji)
    }

    /// Slack's tone suffix number (2...6, `:skin-tone-2:` the lightest) as a tone (1...5); 1 is none.
    static func tone(slack: Int) -> Int? { (1...6).contains(slack) ? slack - 1 : nil }

    /// The `:` just typed at UTF-16 `caret - 1` closes a known `:code:` (or Slack's
    /// `:code::skin-tone-N:`, or `:skin-tone-N:` right after a toneable emoji): the edit writing
    /// the emoji, caret right after it, no space. Unknown codes and code spans: nil.
    public static func closingColon(in text: String, caret: Int, table: EmojiShortcodeTable, tone: Int) -> EmojiEdit? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length, ns.character(at: caret - 1) == 0x3A,
              let found = Self.token(in: ns, caret: caret) else { return nil }
        var (token, start) = (found.token, found.start)
        if let first = token.first, openers.contains(first), token.dropFirst().first == ":" {
            token.removeFirst()
            start += 1
        }
        guard !inCode(ns, at: start) else { return nil }
        // `…:skin-tone-N:`
        if let suffix = token.range(of: #":skin-tone-([1-6]):$"#, options: .regularExpression),
           let slack = Int(String(token[suffix].dropFirst(11).prefix(1))), let toneValue = Self.tone(slack: slack) {
            let head = String(token[..<suffix.lowerBound])
            if head.hasPrefix(":"), head.hasSuffix(":"), head.count > 2, let record = code(in: head, table: table) {
                let glyph = record.glyph(tone: toneValue)
                return EmojiEdit(range: NSRange(location: start, length: caret - start), replacement: glyph,
                                 caret: start + glyph.utf16.count, rememberTone: toneValue, picked: record.emoji)
            }
            if let last = head.last, let record = table.record(glyph: String(last)), record.tones.count == 5 {
                let glyph = record.glyph(tone: toneValue)
                let from = caret - (String(last).utf16.count + token[suffix].utf16.count)
                return EmojiEdit(range: NSRange(location: from, length: caret - from), replacement: glyph,
                                 caret: from + glyph.utf16.count, rememberTone: toneValue, picked: record.emoji)
            }
            return nil
        }
        guard token.hasPrefix(":"), token.count > 2, let record = code(in: token, table: table) else { return nil }
        let glyph = record.glyph(tone: tone)
        return EmojiEdit(range: NSRange(location: start, length: caret - start), replacement: glyph,
                         caret: start + glyph.utf16.count, picked: record.emoji)
    }

    /// The record `:code:` names (case folded), when every letter is a shortcode letter.
    static func code(in colons: String, table: EmojiShortcodeTable) -> EmojiShortcodeRecord? {
        let inner = colons.dropFirst().dropLast()
        guard !inner.isEmpty, inner.allSatisfy(isCodeCharacter) else { return nil }
        return table.record(code: inner.lowercased())
    }

    private static let pasteCode = try! NSRegularExpression(pattern: #":([A-Za-z0-9_+\-]+):(?::skin-tone-([1-6]):)?"#)

    /// Pasted text with each known `:code:` (and Slack's `:code::skin-tone-N:`) written as its
    /// emoji, except inside code spans or fences, URLs, and mid-word (`key:value:`); unknown
    /// codes stay as typed. Returns nil when nothing changes.
    public static func convertingPaste(_ pasted: String, table: EmojiShortcodeTable, tone: Int) -> (text: String, rememberTone: Int?)? {
        guard pasted.contains(":") else { return nil }
        let ns = pasted as NSString
        let out = NSMutableString(string: pasted)
        var remembered: Int?
        var changed = false
        // Back to front, so earlier ranges stay valid.
        for found in pasteCode.matches(in: pasted, range: NSRange(location: 0, length: ns.length)).reversed() {
            let at = found.range.location
            if at > 0, let before = UnicodeScalar(ns.character(at: at - 1)), CharacterSet.alphanumerics.contains(before) { continue }
            if inCode(ns, at: at) { continue }
            if let word = Self.token(in: ns, caret: NSMaxRange(found.range)), word.token.contains("://") { continue }
            guard let record = table.record(code: ns.substring(with: found.range(at: 1)).lowercased()) else { continue }
            var glyphTone = tone
            if found.range(at: 2).location != NSNotFound, let slack = Int(ns.substring(with: found.range(at: 2))),
               let named = Self.tone(slack: slack) {
                glyphTone = named
                if remembered == nil { remembered = named }
            }
            out.replaceCharacters(in: found.range, with: record.glyph(tone: glyphTone))
            changed = true
        }
        return changed ? (out as String, remembered) : nil
    }
}
