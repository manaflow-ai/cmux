public import Foundation

// On-disk format, shared with the `cmux chief memory` CLI
// (CLI/CMUXCLI+Chief.swift implements the same format without linking this
// package). Change both together.
//
// <Chief home>/memory/
//   person.md        the user's profile; written once with a default, then theirs
//   instructions.md  the user's rules for Chief; written once with a comment header
//   memory.jsonl     facts, one JSON object per line, oldest first:
//                    {"createdAt":"2026-10-15T12:00:00Z","id":"m-3fa9c1d2","source":"cli","text":"..."}
//   .lock            flock(2) target; every writer of memory.jsonl holds LOCK_EX
//
// `add` appends one line with a single write(2) on an O_APPEND descriptor while
// holding the lock. `forget` rewrites the file to a temporary sibling and renames
// it over memory.jsonl while holding the lock. Readers take no lock and skip any
// line that does not decode (a torn tail never hides the rest).

/// One durable fact Chief keeps about its user.
public struct ChiefMemoryFact: Codable, Sendable, Equatable, Identifiable {
    /// A short id (`m-` and 8 hex digits) the CLI accepts for `forget`.
    public let id: String
    /// The fact, one line.
    public let text: String
    /// When the fact was saved.
    public let createdAt: Date
    /// Who saved it: `cli` (Chief or the user through `cmux chief memory add`), `app`, or another tag.
    public let source: String

    /// Creates a fact.
    public init(id: String, text: String, createdAt: Date, source: String) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.source = source
    }
}

/// Why a memory write was refused.
public enum ChiefMemoryError: Error, Equatable, Sendable {
    /// The text is empty after trimming.
    case emptyText
    /// The text is longer than ``ChiefMemory/maxFactBytes`` UTF-8 bytes.
    case textTooLong(limit: Int)
    /// The text looks like a credential; memory never stores secrets.
    case looksLikeSecret
    /// No fact has that id.
    case notFound(id: String)
    /// A file system call failed.
    case io(String)
}

/// Where Chief's memory files live.
public struct ChiefMemoryPaths: Sendable, Equatable {
    /// The memory directory (`<Chief home>/memory`).
    public let directory: URL

    /// Paths inside an explicit memory directory.
    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// Paths inside a Chief home's memory directory.
    public init(home: ChiefHome) {
        self.init(directory: home.memoryDirectory)
    }

    /// The user's profile.
    public var person: URL { directory.appendingPathComponent("person.md", isDirectory: false) }
    /// The user's rules for Chief.
    public var instructions: URL { directory.appendingPathComponent("instructions.md", isDirectory: false) }
    /// The saved facts, JSON Lines.
    public var facts: URL { directory.appendingPathComponent("memory.jsonl", isDirectory: false) }
    /// The lock every writer of ``facts`` holds.
    public var lock: URL { directory.appendingPathComponent(".lock", isDirectory: false) }
}

/// The texts the system prompt injects, read once at session start.
public struct ChiefMemorySnapshot: Sendable, Equatable {
    /// person.md, or empty when it holds only comments.
    public let person: String
    /// instructions.md, or empty when it holds only comments.
    public let instructions: String
    /// The rendered, size-capped fact list (empty when there are no facts).
    public let memory: String

    /// Creates a snapshot.
    public init(person: String, instructions: String, memory: String) {
        self.person = person
        self.instructions = instructions
        self.memory = memory
    }
}

/// File-backed long-term memory for Chief, safe to use from the app and the
/// CLI at the same time.
///
/// ```swift
/// let memory = ChiefMemory(paths: ChiefMemoryPaths(home: .resolve()))
/// try memory.ensureDefaults()
/// let fact = try memory.add("Prefers Codex for backend work", source: "app")
/// let block = memory.snapshot().memory
/// ```
public struct ChiefMemory: Sendable {
    /// The rendered fact block's size cap in UTF-8 bytes.
    public static let renderCapBytes = 16 * 1024
    /// The longest fact accepted, in UTF-8 bytes.
    public static let maxFactBytes = 1_000

    /// The files this memory reads and writes.
    public let paths: ChiefMemoryPaths
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String

    /// Creates a memory over `paths`.
    ///
    /// - Parameters:
    ///   - paths: The memory directory's files.
    ///   - now: The clock for `createdAt` (tests inject a fixed one).
    ///   - makeID: The id generator (tests inject a counter).
    public init(paths: ChiefMemoryPaths,
                now: @escaping @Sendable () -> Date = { Date() },
                makeID: @escaping @Sendable () -> String = { ChiefMemory.randomID() }) {
        self.paths = paths
        self.now = now
        self.makeID = makeID
    }

    /// `m-` and 8 lowercase hex digits.
    public static func randomID() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "m-" + hex.prefix(8)
    }

    // MARK: Profile files

    /// The default person.md, written once when the file is missing.
    public static let defaultPerson = """
    <!-- Your profile for Chief. Chief reads it at the start of each conversation. Edit it freely: who you are, your machines, repos and projects, and how you like work done. -->

    - Act without asking for safe operations: reading, searching, read-only commands, edits in a worktree or scratch folder. When I asked for the work, do it and report.
    - Ask first only for money, legal matters, physical actions and destructive actions (deleting data, force pushes, production changes, closing workspaces or machines I did not name).
    - When you name a page, PR, build or file, give its real URL or absolute path.
    """

    /// The default instructions.md, written once when the file is missing.
    public static let defaultInstructions = """
    <!-- Your rules for Chief, one per line. Chief follows them in every conversation. Example: "Start coding agents with codex --yolo in a new worktree." -->
    """

    /// Creates the memory directory and writes the default person.md and
    /// instructions.md when they are missing. Never overwrites user edits.
    public func ensureDefaults() throws {
        do {
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw ChiefMemoryError.io("\(error)")
        }
        for (url, text) in [(paths.person, Self.defaultPerson), (paths.instructions, Self.defaultInstructions)] {
            // O_EXCL: two processes racing on first run never clobber each other.
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else {
                if errno == EEXIST { continue }
                throw ChiefMemoryError.io("open \(url.path): \(String(cString: strerror(errno)))")
            }
            defer { close(fd) }
            try Self.writeAll(fd: fd, data: Data((text + "\n").utf8))
        }
    }

    /// The profile and instructions plus the rendered facts, for the system prompt.
    public func snapshot(capBytes: Int = ChiefMemory.renderCapBytes) -> ChiefMemorySnapshot {
        ChiefMemorySnapshot(
            person: Self.meaningfulText(Self.read(paths.person)),
            instructions: Self.meaningfulText(Self.read(paths.instructions)),
            memory: Self.render(facts: facts(), capBytes: capBytes)
        )
    }

    // MARK: Facts

    /// Every saved fact, oldest first. Undecodable lines are skipped.
    public func facts() -> [ChiefMemoryFact] {
        Self.decodeLines(Self.read(paths.facts))
    }

    /// Saves a fact.
    ///
    /// - Parameters:
    ///   - text: The fact; newlines and runs of spaces collapse to one space.
    ///   - source: Who saved it (`chief` in a turn, `cli` from a terminal, `app`, ...).
    /// - Returns: The saved fact with its new id.
    /// - Throws: ``ChiefMemoryError`` when the text is empty, too long, looks like a secret, or the write fails.
    @discardableResult
    public func add(_ text: String, source: String) throws -> ChiefMemoryFact {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { throw ChiefMemoryError.emptyText }
        guard normalized.utf8.count <= Self.maxFactBytes else {
            throw ChiefMemoryError.textTooLong(limit: Self.maxFactBytes)
        }
        guard !Self.looksLikeSecret(normalized) else { throw ChiefMemoryError.looksLikeSecret }
        // Whole seconds, so a fact round-trips through the ISO 8601 line unchanged.
        let createdAt = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let fact = ChiefMemoryFact(id: makeID(), text: normalized, createdAt: createdAt, source: source)
        let line = try Self.encodeLine(fact)
        try withLock {
            let fd = open(paths.facts.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { throw ChiefMemoryError.io("open \(paths.facts.path): \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            try Self.writeAll(fd: fd, data: line)
        }
        return fact
    }

    /// Removes a fact.
    ///
    /// - Parameter id: The fact's id, as `list` prints it.
    /// - Returns: The removed fact.
    /// - Throws: ``ChiefMemoryError/notFound(id:)`` when no fact has that id.
    @discardableResult
    public func forget(_ id: String) throws -> ChiefMemoryFact {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return try withLock {
            let all = facts()
            guard let removed = all.first(where: { $0.id == wanted }) else {
                throw ChiefMemoryError.notFound(id: wanted)
            }
            try rewrite(all.filter { $0.id != wanted })
            return removed
        }
    }

    /// Replaces a fact's text while keeping its id, source and timestamp.
    ///
    /// Editing is deliberately a rewrite under the same lock as ``forget``;
    /// readers either see the old complete file or the new complete file.
    /// The same validation as ``add`` prevents the sheet from becoming a way
    /// around the memory store's secret and size limits.
    @discardableResult
    public func update(_ id: String, text: String) throws -> ChiefMemoryFact {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { throw ChiefMemoryError.emptyText }
        guard normalized.utf8.count <= Self.maxFactBytes else {
            throw ChiefMemoryError.textTooLong(limit: Self.maxFactBytes)
        }
        guard !Self.looksLikeSecret(normalized) else { throw ChiefMemoryError.looksLikeSecret }
        return try withLock {
            let all = facts()
            guard let old = all.first(where: { $0.id == wanted }) else {
                throw ChiefMemoryError.notFound(id: wanted)
            }
            let updated = ChiefMemoryFact(id: old.id, text: normalized, createdAt: old.createdAt, source: old.source)
            try rewrite(all.map { $0.id == wanted ? updated : $0 })
            return updated
        }
    }

    /// Atomically rewrites the JSONL file while the caller holds the lock.
    private func rewrite(_ facts: [ChiefMemoryFact]) throws {
        var data = Data()
        for fact in facts { data.append(try Self.encodeLine(fact)) }
        let temporary = paths.directory.appendingPathComponent(".memory.jsonl.\(getpid()).tmp")
        do {
            try data.write(to: temporary, options: [])
            _ = chmod(temporary.path, 0o600)
            guard rename(temporary.path, paths.facts.path) == 0 else {
                throw ChiefMemoryError.io("rename: \(String(cString: strerror(errno)))")
            }
        } catch let error as ChiefMemoryError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ChiefMemoryError.io("\(error)")
        }
    }

    // MARK: Rendering

    /// Renders facts as a Markdown list, newest first, within `capBytes`
    /// UTF-8 bytes; the oldest facts that do not fit are left out and counted.
    public static func render(facts: [ChiefMemoryFact], capBytes: Int = renderCapBytes) -> String {
        guard !facts.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        var omitted = 0
        for fact in facts.reversed() {
            let line = "- \(fact.text) (\(fact.id), \(dayString(fact.createdAt)))"
            let cost = line.utf8.count + 1
            if omitted == 0, used + cost <= capBytes {
                lines.append(line)
                used += cost
            } else {
                omitted += 1
            }
        }
        if omitted > 0 {
            lines.append("- (\(omitted) older facts not shown; run `cmux chief memory list` to see them)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Text rules

    /// Trims and collapses whitespace (newlines included) to single spaces.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// True for text that carries a credential-shaped token or a private key.
    public static func looksLikeSecret(_ text: String) -> Bool {
        let patterns = [
            #"(?i)BEGIN [A-Z ]*PRIVATE KEY"#,
            #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}"#,
            #"(?<![A-Za-z0-9])[sr]k_(live|test)_[A-Za-z0-9]{10,}"#,
            #"(?<![A-Za-z0-9])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
            #"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}"#,
            #"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{20,}"#,
            #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}"#,
            #"(?<![A-Za-z0-9])xox[abprse]-[A-Za-z0-9\-]{10,}"#,
            #"(?<![A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}"#,
            #"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}"#,
            #"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
            // `AWS_SECRET_ACCESS_KEY=…`, `GITHUB_TOKEN: …`, `my-api-key = …`: a credential name, then a value.
            #"(?i)(^|[^a-z])(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)[a-z0-9_\-]*["']?\s*[:=]\s*\S{6,}"#,
            #"://[^/\s:@]+:[^/\s@]+@"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The text with HTML comments removed and trimmed; empty when nothing else remains.
    public static func meaningfulText(_ text: String) -> String {
        var out = text
        while let start = out.range(of: "<!--") {
            guard let end = out.range(of: "-->", range: start.upperBound..<out.endIndex) else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
                break
            }
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Internals

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw ChiefMemoryError.io("\(error)")
        }
        let fd = open(paths.lock.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw ChiefMemoryError.io("open \(paths.lock.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ChiefMemoryError.io("flock: \(String(cString: strerror(errno)))") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ChiefMemoryError.io("write: \(String(cString: strerror(errno)))")
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func encodeLine(_ fact: ChiefMemoryFact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            var data = try encoder.encode(fact)
            data.append(0x0A)
            return data
        } catch {
            throw ChiefMemoryError.io("\(error)")
        }
    }

    static func decodeLines(_ text: String) -> [ChiefMemoryFact] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(ChiefMemoryFact.self, from: Data(line.utf8))
        }
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
