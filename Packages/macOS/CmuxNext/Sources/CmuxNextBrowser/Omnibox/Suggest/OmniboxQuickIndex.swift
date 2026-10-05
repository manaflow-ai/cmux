public import Foundation

/// One row the quick index found for an input.
public nonisolated struct OmniboxQuickMatch: Hashable, Sendable {
    public var row: OmniboxHistoryRow
    public var score: Double
    /// The input is the start of the row's URL at its host.
    public var hostPrefix: Bool
    /// Inline autocomplete may complete to this row (`OmniboxQuickScore.allowsInlineCompletion`).
    public var allowsInlineCompletion: Bool
    /// `BrowserHistoryRanker.dedupeKey(for: row.url)` and the display URL, computed once at index time.
    public var key: String
    public var display: String

    /// Higher score first, then URL text, so equal input always gives equal output.
    public static func ranks(_ lhs: OmniboxQuickMatch, before rhs: OmniboxQuickMatch) -> Bool {
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.row.url.absoluteString < rhs.row.url.absoluteString
    }
}

/// The omnibar's in-memory history index (plans/cmux-next/omnibar-suggestions.md,
/// "Quick history index"): one entry per URL, and one sorted array of
/// (word, entry) pairs over the URL's and the title's words, so a word-prefix
/// lookup is a binary search. Multi-word input starts from the rarest word's
/// entries and keeps those whose words cover every other word. Words match at
/// their start; a match inside a word is left to the deep history pass.
/// A value type: the phase A actor owns one per source and nothing shares it.
public nonisolated struct OmniboxQuickIndex: Sendable {
    /// Which rows enter the index.
    public enum Admission: Sendable {
        /// History: typed once, visited twice, or visited in the last 72 hours.
        case significant
        /// Bookmarks and open tabs: every row.
        case all
    }

    public static let defaultCap = 20_000
    static let recentWindow: TimeInterval = 72 * 3_600

    /// One indexed URL with everything a lookup reads, precomputed. A
    /// class, so a lookup touches a reference instead of copying the fields.
    nonisolated final class Entry: Sendable {
        let row: OmniboxHistoryRow
        let key: String
        /// The display URL as shown (`BrowserURLDisplay`).
        let display: String
        /// Lowercased display URL, and the same without `http://`.
        let url: String
        let bare: String
        /// Lowercased host without `www.`.
        let host: String
        /// " " + the lowercased title.
        let titleSpaced: String
        let words: [String]
        /// The host's first word: a host-prefix match always reaches the row
        /// through this word's pair. When it is not one of `words` (or the
        /// host has no word), every pair may carry one (`anyWordLeads`).
        let hostWord: String?
        let anyWordLeads: Bool
        /// The first word of the display URL and the title's words: the only
        /// words a URL-prefix (450) or title-word (300) match can start.
        let urlWord: String?
        let titleWords: [String]
        /// `OmniboxQuickScore.usage` and `.brevity`.
        let usage: Double
        let brevity: Double
        /// `usage + brevity`: the part of the score fixed at index time.
        let fixed: Double

        init(_ row: OmniboxHistoryRow) {
            let display = BrowserURLDisplay.displayText(for: row.url)
            let url = display.lowercased()
            let bare = url.hasPrefix("http://") ? String(url.dropFirst(7)) : url
            var host = row.url.host(percentEncoded: false)?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let title = row.title?.lowercased() ?? ""
            var seen = Set<String>()
            let usage = OmniboxQuickScore.usage(visitCount: row.visitCount, typedCount: row.typedCount)
            let brevity = OmniboxQuickScore.brevity(urlLength: url.count)
            self.row = row
            self.display = display
            self.url = url
            self.bare = bare
            // `BrowserHistoryRanker.dedupeKey`, without a second display pass.
            key = bare.hasSuffix("/") ? String(bare.dropLast()) : bare
            self.host = host
            titleSpaced = " " + title
            let urlWords = OmniboxText.words(bare)
            let titleWords = OmniboxText.words(title)
            words = (urlWords + titleWords).filter { seen.insert($0).inserted }
            self.titleWords = titleWords
            urlWord = OmniboxText.words(url).first
            let lead = OmniboxText.words(host).first
            hostWord = lead
            anyWordLeads = !host.isEmpty && !(lead.map { seen.contains($0) } ?? false)
            self.usage = usage
            self.brevity = brevity
            fixed = usage + brevity
        }

        /// Whether a host-prefix match may reach this row through `word`.
        func leads(_ word: String) -> Bool { anyWordLeads || word == hostWord }

        /// Whether a host-prefix match may reach this row through a word starting with `prefix`.
        func leadsPrefix(_ prefix: String) -> Bool { anyWordLeads || (hostWord?.hasPrefix(prefix) ?? false) }

        /// The best first-token match term through a word starting with
        /// `prefix`: 600 when it may start the host, 450 the URL, 300 a title
        /// word, else 150 (a substring).
        func cap(_ prefix: String) -> Double {
            if leadsPrefix(prefix) { return OmniboxQuickScore.hostPrefix }
            if urlWord?.hasPrefix(prefix) == true { return OmniboxQuickScore.urlPrefix }
            if titleWords.contains(where: { $0.hasPrefix(prefix) }) { return OmniboxQuickScore.titleWord }
            return OmniboxQuickScore.substring
        }

        /// The prefixes of its words up to `OmniboxQuickIndex.shortLength` characters (`shortLists` keys).
        var shortPrefixes: Set<String> {
            Set(words.flatMap { word in (1...OmniboxQuickIndex.shortLength).map { String(word.prefix($0)) } })
        }
    }

    public let cap: Int
    public let admission: Admission
    var entries: [Entry?] = []
    /// `entries[id]?.fixed`, unboxed, so pruning reads no entry (-inf: free).
    var fixed: [Double] = []
    var ids: [String: Int32] = [:]
    var freeIDs: [Int32] = []
    /// Sorted by word; `wordEntries[i]` is the entry of `words[i]`, and
    /// `wordStartsHost[i]` says whether the word starts that entry's host.
    var words: [String] = []
    var wordEntries: [Int32] = []
    var wordStartsHost: [Bool] = []
    /// Prefixes up to this many characters get a `shortLists` entry.
    static let shortLength = 3
    /// For every prefix of one to `shortLength` characters, the entries with a word that
    /// starts with it, by their best score through that prefix
    /// (`fixed + cap`, highest first; ties: lower id). A short input matches
    /// thousands of rows; walking them best-first stops as soon as no
    /// further row can enter the result.
    var shortLists: [String: [ShortItem]] = [:]

    struct ShortItem: Sendable {
        var id: Int32
        /// `fixed + cap(prefix)`: the score without recency at best.
        var key: Double

        func precedes(_ other: ShortItem) -> Bool { key != other.key ? key > other.key : id < other.id }
    }

    public init(cap: Int = OmniboxQuickIndex.defaultCap, admission: Admission = .significant) {
        self.cap = cap
        self.admission = admission
    }

    /// URLs in the index.
    public var count: Int { ids.count }

    public func contains(_ url: URL) -> Bool { ids[BrowserHistoryRanker.dedupeKey(for: url)] != nil }

    public mutating func apply(_ change: OmniboxHistoryChange, now: Date) {
        switch change {
        case .reset(let rows): reset(rows, now: now)
        case .upsert(let rows): rows.forEach { upsert($0, now: now) }
        case .remove(let urls): urls.forEach { remove($0) }
        }
    }

    // MARK: Building

    /// Replaces every entry. Over `cap`, the rows with the lowest usage and
    /// recency stay out.
    public mutating func reset(_ rows: [OmniboxHistoryRow], now: Date) {
        var unique: [String: Entry] = [:]
        for row in rows where admits(row, now: now) {
            let entry = Self.entry(row)
            if let existing = unique[entry.key], existing.row.lastVisit >= row.lastVisit { continue }
            unique[entry.key] = entry
        }
        var kept = Array(unique.values)
        if kept.count > cap {
            kept.sort { Self.retention($0, now: now) > Self.retention($1, now: now) }
            kept.removeLast(kept.count - cap)
        }
        entries = kept.map { Optional($0) }
        fixed = kept.map(\.fixed)
        freeIDs = []
        ids = [:]
        var pairs: [(word: String, id: Int32, startsHost: Bool)] = []
        for (index, entry) in kept.enumerated() {
            ids[entry.key] = Int32(index)
            pairs += entry.words.map { ($0, Int32(index), entry.leads($0)) }
        }
        pairs.sort { $0.word != $1.word ? $0.word < $1.word : $0.id < $1.id }
        words = pairs.map(\.word)
        wordEntries = pairs.map(\.id)
        wordStartsHost = pairs.map(\.startsHost)
        var lists: [String: [ShortItem]] = [:]
        for (index, entry) in kept.enumerated() {
            for prefix in entry.shortPrefixes {
                lists[prefix, default: []].append(ShortItem(id: Int32(index), key: entry.fixed + entry.cap(prefix)))
            }
        }
        shortLists = lists.mapValues { $0.sorted { $0.precedes($1) } }
    }

    /// Adds or replaces one URL; a row that is no longer admitted leaves.
    public mutating func upsert(_ row: OmniboxHistoryRow, now: Date) {
        let entry = Self.entry(row)
        if let id = ids[entry.key] {
            unlinkWords(of: id)
            guard admits(row, now: now) else { return drop(id, key: entry.key) }
            entries[Int(id)] = entry
            fixed[Int(id)] = entry.fixed
            linkWords(of: id)
            return
        }
        guard admits(row, now: now) else { return }
        if ids.count >= cap {
            guard let weakest = weakestID(now: now),
                  let weakestEntry = entries[Int(weakest)],
                  Self.retention(weakestEntry, now: now) < Self.retention(entry, now: now) else { return }
            unlinkWords(of: weakest)
            drop(weakest, key: weakestEntry.key)
        }
        let id: Int32
        if let reused = freeIDs.popLast() {
            id = reused
            entries[Int(id)] = entry
            fixed[Int(id)] = entry.fixed
        } else {
            id = Int32(entries.count)
            entries.append(entry)
            fixed.append(entry.fixed)
        }
        ids[entry.key] = id
        linkWords(of: id)
    }

    public mutating func remove(_ url: URL) {
        let key = BrowserHistoryRanker.dedupeKey(for: url)
        guard let id = ids[key] else { return }
        unlinkWords(of: id)
        drop(id, key: key)
    }

    func admits(_ row: OmniboxHistoryRow, now: Date) -> Bool {
        switch admission {
        case .all: true
        case .significant: row.typedCount > 0 || row.visitCount >= 2 || now.timeIntervalSince(row.lastVisit) <= Self.recentWindow
        }
    }

    static func entry(_ row: OmniboxHistoryRow) -> Entry { Entry(row) }

    /// What decides which rows leave first over the cap.
    static func retention(_ entry: Entry, now: Date) -> Double {
        entry.usage + OmniboxQuickScore.recency(lastVisit: entry.row.lastVisit, now: now)
    }

    private func weakestID(now: Date) -> Int32? {
        var weakest: (id: Int32, value: Double)?
        for (index, entry) in entries.enumerated() {
            guard let entry else { continue }
            let value = Self.retention(entry, now: now)
            if weakest.map({ value < $0.value }) ?? true { weakest = (Int32(index), value) }
        }
        return weakest?.id
    }

    private mutating func drop(_ id: Int32, key: String) {
        entries[Int(id)] = nil
        fixed[Int(id)] = -.infinity
        ids[key] = nil
        freeIDs.append(id)
    }

    private mutating func linkWords(of id: Int32) {
        guard let entry = entries[Int(id)] else { return }
        for word in entry.words {
            let index = lowerBound(word)
            words.insert(word, at: index)
            wordEntries.insert(id, at: index)
            wordStartsHost.insert(entry.leads(word), at: index)
        }
        for prefix in entry.shortPrefixes {
            let item = ShortItem(id: id, key: entry.fixed + entry.cap(prefix))
            var list = shortLists[prefix] ?? []
            list.insert(item, at: Self.slot(of: item, in: list))
            shortLists[prefix] = list
        }
    }

    /// Where `item` goes (or is) in a short list.
    static func slot(of item: ShortItem, in list: [ShortItem]) -> Int {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].precedes(item) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private mutating func unlinkWords(of id: Int32) {
        guard let entry = entries[Int(id)] else { return }
        for word in entry.words {
            var index = lowerBound(word)
            while index < words.count, words[index] == word {
                if wordEntries[index] == id {
                    words.remove(at: index)
                    wordEntries.remove(at: index)
                    wordStartsHost.remove(at: index)
                    break
                }
                index += 1
            }
        }
        for prefix in entry.shortPrefixes {
            guard var list = shortLists[prefix] else { continue }
            let slot = Self.slot(of: ShortItem(id: id, key: entry.fixed + entry.cap(prefix)), in: list)
            if list.indices.contains(slot), list[slot].id == id {
                list.remove(at: slot)
            } else if let found = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: found)
            }
            shortLists[prefix] = list.isEmpty ? nil : list
        }
    }

    // MARK: Lookup

    /// The first index whose word is not below `word`.
    func lowerBound(_ word: String) -> Int {
        var low = 0, high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle] < word { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The pairs whose word starts with `prefix`: words below the prefix come
    /// first, then every word with the prefix, then the rest.
    func prefixRange(_ prefix: String) -> Range<Int> {
        let start = lowerBound(prefix)
        var low = start, high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].hasPrefix(prefix) { low = middle + 1 } else { high = middle }
        }
        return start..<low
    }
}
