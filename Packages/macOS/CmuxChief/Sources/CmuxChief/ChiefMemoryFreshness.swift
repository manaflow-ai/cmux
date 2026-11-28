public import CmuxHomeCore
import Foundation

/// What Chief's memory held at one moment: person.md and instructions.md
/// (comments stripped) and every saved fact, with a stable digest.
///
/// A brain reads its system prompt (and the memory in it) only when its
/// session starts: Claude Code when its long-lived process launches, Codex at
/// `thread/start`. ``ChiefMemoryFreshness`` keeps the state each session
/// started with and turns any later edit into a ``ChiefMemoryState/update(from:)``
/// block the next turn carries in its user text.
public struct ChiefMemoryState: Sendable, Equatable {
    /// One saved fact, as the update block names it.
    public struct Fact: Sendable, Equatable {
        /// The fact's id (`m-` and 8 hex digits).
        public let id: String
        /// The fact.
        public let text: String

        /// Creates a fact.
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// person.md without comments.
    public let person: String
    /// instructions.md without comments.
    public let instructions: String
    /// Every saved fact, oldest first.
    public let facts: [Fact]
    /// FNV-1a 64 over the fields above; stable across launches.
    public let digest: UInt64

    /// A text edit at or below this many UTF-8 bytes is shown in full; a
    /// larger one as its added and removed lines.
    public static let fullTextLimitBytes = 4 * 1024

    /// Creates a state.
    public init(person: String, instructions: String, facts: [Fact]) {
        self.person = person
        self.instructions = instructions
        self.facts = facts
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0xff
            hash = hash &* 0x0000_0100_0000_01b3
        }
        mix(person)
        mix(instructions)
        for fact in facts {
            mix(fact.id)
            mix(fact.text)
        }
        digest = hash
    }

    /// The memory's current state, read from disk.
    public init(memory: ChiefMemory) {
        self.init(person: ChiefMemory.meaningfulText(Self.read(memory.paths.person)),
                  instructions: ChiefMemory.meaningfulText(Self.read(memory.paths.instructions)),
                  facts: memory.facts().map { Fact(id: $0.id, text: $0.text) })
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The `<memory-update>` block that brings a session started at `old` up
    /// to this state; nil when nothing changed.
    ///
    /// Model-facing text: not localized.
    public func update(from old: ChiefMemoryState) -> String? {
        guard digest != old.digest else { return nil }
        var sections: [String] = []
        if instructions != old.instructions {
            sections.append(Self.textChange(title: "Your instructions (instructions.md) changed", old: old.instructions,
                                            new: instructions))
        }
        if person != old.person {
            sections.append(Self.textChange(title: "The user's profile (person.md) changed", old: old.person, new: person))
        }
        let oldIDs = Set(old.facts.map(\.id))
        let newIDs = Set(facts.map(\.id))
        let added = facts.filter { !oldIDs.contains($0.id) }
        let removed = old.facts.filter { !newIDs.contains($0.id) }
        if !added.isEmpty {
            sections.append("New saved facts:\n" + Self.capped(added.map { "- \($0.text) (\($0.id))" }))
        }
        if !removed.isEmpty {
            sections.append("Forgotten facts (no longer true or wanted):\n"
                + Self.capped(removed.map { "- \($0.text) (\($0.id))" }))
        }
        guard !sections.isEmpty else { return nil }
        return """
        <memory-update>
        The user's memory changed since this conversation's system prompt was written. These replace what the system prompt says; follow them from now on.

        \(sections.joined(separator: "\n\n"))
        </memory-update>
        """
    }

    private static func textChange(title: String, old: String, new: String) -> String {
        if new.isEmpty { return "\(title): it is now empty; drop what it said before." }
        if new.utf8.count <= fullTextLimitBytes { return "\(title). It now reads:\n\n\(new)" }
        let oldLines = Set(old.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let newSet = Set(newLines)
        var diff = newLines.filter { !oldLines.contains($0) }.map { "+ \($0)" }
        diff += old.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !newSet.contains($0) }.map { "- \($0)" }
        return "\(title); it is too long to repeat. Lines added (+) and removed (-):\n" + capped(diff)
    }

    /// The lines within ``fullTextLimitBytes``, then a count of the rest.
    private static func capped(_ lines: [String]) -> String {
        var kept: [String] = []
        var used = 0
        for (index, line) in lines.enumerated() {
            used += line.utf8.count + 1
            if used > fullTextLimitBytes {
                kept.append("(\(lines.count - index) more lines; read the file or `cmux chief memory list`)")
                break
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}

/// The memory state each conversation's brain session started with, so a
/// turn learns about memory edits made since (P1-5).
///
/// A turn with no session to resume starts a fresh one, whose system prompt
/// already holds the current memory: its state becomes the baseline. So does
/// the first turn this app run sees for a conversation (after a relaunch the
/// brain's process starts again with the current prompt). Any later turn
/// compares and, when memory changed, gets a preamble and moves the baseline.
public actor ChiefMemoryFreshness {
    private var baselines: [ConversationID: ChiefMemoryState] = [:]

    /// Creates an empty tracker.
    public init() {}

    /// The `<memory-update>` block for this turn, nil when the session's memory is current.
    ///
    /// - Parameters:
    ///   - conversation: The conversation the turn answers in.
    ///   - freshSession: True when the turn starts a new brain session
    ///     (``ChiefTurnContextInput/resumeSession`` is nil).
    ///   - current: The memory now.
    public func preamble(for conversation: ConversationID, freshSession: Bool, current: ChiefMemoryState) -> String? {
        guard !freshSession, let baseline = baselines[conversation] else {
            baselines[conversation] = current
            return nil
        }
        baselines[conversation] = current
        return current.update(from: baseline)
    }

    /// Forgets a conversation's baseline (its session ended).
    public func reset(_ conversation: ConversationID) {
        baselines[conversation] = nil
    }
}
