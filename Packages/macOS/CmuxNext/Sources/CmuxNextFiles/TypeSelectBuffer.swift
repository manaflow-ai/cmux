public import Foundation

/// Finder's type-select: typed letters within a short pause build a prefix,
/// and the first item at or after that prefix in name order is selected.
public struct TypeSelectBuffer: Sendable {
    /// Typing pauses longer than this start a new prefix (Finder: about 1 s).
    public var timeout: TimeInterval
    private var text = ""
    private var last: Date?

    /// Makes an empty buffer.
    public init(timeout: TimeInterval = 1.0) { self.timeout = timeout }

    /// The prefix after typing `characters` at `now`.
    public mutating func type(_ characters: String, at now: Date) -> String {
        if let last, now.timeIntervalSince(last) > timeout { text = "" }
        last = now
        text += characters
        return text
    }

    /// The index in `entries` (in name order) that type-select picks for
    /// `prefix`: the first whose name starts with it, else the first that
    /// sorts after it (Finder lands on the nearest item), else the last.
    public func match(_ prefix: String, in entries: [FileEntry]) -> Int? {
        guard !entries.isEmpty, !prefix.isEmpty else { return nil }
        let needle = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let exact = entries.firstIndex(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(needle)
        }) { return exact }
        let key = FileNameSortKey(prefix)
        let after = entries.indices.filter { entries[$0].sortKey.compare(key) > 0 }
            .min { entries[$0].sortKey < entries[$1].sortKey }
        return after ?? entries.indices.last
    }
}
