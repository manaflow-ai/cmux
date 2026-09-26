import Foundation

/// Durable notes the user told the voice assistant to keep: preferences,
/// defaults, standing instructions ("my main repo is ~/dev/cmux", "keep
/// replies short"). Persisted as a JSON file on the device's disk
/// (Application Support), injected into every voice session's instructions,
/// and edited through the orchestrator's remember / forget_memory /
/// list_memories tools.
///
/// Disk, not UserDefaults: memory can grow large, and UserDefaults is a
/// preferences plist loaded whole into every process. The store still bounds
/// itself (entry count, entry length) so the file stays readable in one
/// synchronous load, and the SESSION-PROMPT injection is budgeted separately
/// (`promptBudgetCharacters`, newest notes win) because instructions cannot
/// carry megabytes regardless of what the disk holds.
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

    public static let maximumEntries = 5_000
    public static let maximumEntryLength = 4_000
    /// Budget for the block injected into session instructions; oldest
    /// entries fall off first when the rendered list exceeds it.
    public static let promptBudgetCharacters = 2_000
    /// Budget for the list_memories tool result, which can afford more than
    /// the always-present prompt block.
    public static let toolListBudgetCharacters = 8_000

    /// Pre-disk builds kept memories in UserDefaults; imported once.
    private static let legacyDefaultsKey = "cmux.mobile.voice.memories"

    private let fileURL: URL
    public private(set) var entries: [Entry]

    /// The production store location: Application Support/cmux-voice/memories.json.
    public nonisolated static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("cmux-voice", isDirectory: true)
            .appendingPathComponent("memories.json")
    }

    /// - Parameters:
    ///   - fileURL: Backing file; tests pass a temporary location.
    ///   - migratingFrom: Defaults that may hold the pre-disk store; imported
    ///     into the file once and removed. Pass nil to skip migration.
    public init(
        fileURL: URL = MobileVoiceMemory.defaultFileURL(),
        migratingFrom legacyDefaults: UserDefaults? = .standard
    ) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else if let legacyDefaults,
                  let data = legacyDefaults.data(forKey: Self.legacyDefaultsKey),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
            persist()
            legacyDefaults.removeObject(forKey: Self.legacyDefaultsKey)
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
        summary(budget: Self.promptBudgetCharacters)
    }

    /// The larger rendering for the list_memories tool.
    public var toolListSummary: String? {
        summary(budget: Self.toolListBudgetCharacters)
    }

    private func summary(budget: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        var lines: [String] = []
        var total = 0
        for entry in entries.reversed() {
            let line = "- \(entry.text)"
            total += line.count + 1
            if total > budget { break }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return lines.reversed().joined(separator: "\n")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }
}
