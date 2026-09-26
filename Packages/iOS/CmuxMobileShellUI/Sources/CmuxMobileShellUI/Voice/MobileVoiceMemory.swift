import Foundation

/// Durable notes the user told the voice assistant to keep: preferences,
/// defaults, standing instructions ("my main repo is ~/dev/cmux", "keep
/// replies short"). Persisted to the injected `UserDefaults`, injected into
/// every voice session's instructions, and edited through the orchestrator's
/// remember / forget_memory / list_memories tools.
///
/// Deliberately small and bounded: memories ride inside the session prompt,
/// so the store caps entry length and count and evicts oldest-first.
@MainActor
public final class MobileVoiceMemory {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let text: String
        public let createdAt: Date

        public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    public static let maximumEntries = 100
    public static let maximumEntryLength = 500
    /// Budget for the block injected into session instructions; oldest
    /// entries fall off first when the rendered list exceeds it.
    public static let promptBudgetCharacters = 2_000

    private static let defaultsKey = "cmux.mobile.voice.memories"

    // UserDefaults is Apple-documented thread-safe; reads/writes here happen
    // on the main actor anyway.
    private nonisolated(unsafe) let defaults: UserDefaults
    public private(set) var entries: [Entry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Save one fact. Trims, caps length, drops an exact duplicate (the
    /// existing entry is refreshed to newest instead), and evicts the oldest
    /// entry beyond the cap. Returns the stored text, or nil for empty input.
    @discardableResult
    public func remember(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > Self.maximumEntryLength {
            trimmed = String(trimmed.prefix(Self.maximumEntryLength))
        }
        entries.removeAll { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.append(Entry(text: trimmed))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        persist()
        return trimmed
    }

    /// Remove every entry whose text contains `query` (case-insensitive).
    /// Returns how many were removed.
    public func forget(matching query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let before = entries.count
        entries.removeAll { $0.text.range(of: needle, options: .caseInsensitive) != nil }
        let removed = before - entries.count
        if removed > 0 { persist() }
        return removed
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        persist()
    }

    /// The bulleted block injected into session instructions, oldest first so
    /// later corrections read after what they correct; nil when empty.
    /// Trims oldest entries beyond the prompt budget.
    public var promptSummary: String? {
        guard !entries.isEmpty else { return nil }
        var lines: [String] = []
        var total = 0
        for entry in entries.reversed() {
            let line = "- \(entry.text)"
            total += line.count + 1
            if total > Self.promptBudgetCharacters { break }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return lines.reversed().joined(separator: "\n")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
