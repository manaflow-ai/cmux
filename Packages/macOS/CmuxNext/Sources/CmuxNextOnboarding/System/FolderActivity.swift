public import Foundation
import CmuxNextCompat

/// How active the user has been in folders, from the shell's own records,
/// read without asking (https://github.com/manaflow-ai/cmux/issues/46904):
///
/// - zoxide: `db.zo` in `$_ZO_DATA_DIR`, `~/Library/Application Support/zoxide`
///   or `~/.local/share/zoxide` (each folder's rank and last visit).
/// - z / zsh-z: `$_Z_DATA` or `~/.z` (`path|rank|epoch` lines).
/// - Shell history: `cd` and `pushd` to an absolute or `~` path in
///   `~/.zsh_history`, `~/.bash_history` and fish's `fish_history` (the
///   newest part of each file only).
///
/// Every one of these files lives in the home folder or its dot folders,
/// never in a privacy-protected location, so reading them raises no prompt.
/// A visited path inside a `PrivacyFolder` is dropped by its spelling
/// before anything looks at it (`RecentProjectScan`).
public nonisolated struct FolderActivity: Sendable, Equatable {
    /// One folder's visits: a weight (zoxide or z rank, else one per
    /// history line) and the newest visit that has a time.
    public struct Visits: Sendable, Equatable {
        public var weight: Double
        public var last: Date

        public init(weight: Double, last: Date) {
            self.weight = weight
            self.last = last
        }
    }

    /// Visits by standardized absolute path.
    public var visits: [String: Visits]

    public init(visits: [String: Visits] = [:]) { self.visits = visits }

    /// The newest bytes of a history file that are read.
    static let historyTail = 2 * 1024 * 1024
    /// The most bytes of a zoxide or z database that are read.
    static let databaseLimit = 8 * 1024 * 1024
    /// zoxide rank is a frecency that grows by 1 per visit; z's grows the same way. Both are
    /// capped so one folder visited thousands of times does not drown out everything else.
    static let maxWeight = 200.0

    /// Reads every source under `home`, honoring `_ZO_DATA_DIR`, `_Z_DATA` and `HISTFILE`.
    public static func read(home: URL, environment: [String: String] = [:], now: Date = Date()) -> FolderActivity {
        var activity = FolderActivity()
        func dir(_ key: String) -> URL? {
            environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        }
        var zoxide = [home.appending(path: "Library/Application Support/zoxide/db.zo"),
                      home.appending(path: ".local/share/zoxide/db.zo")]
        if let custom = dir("_ZO_DATA_DIR") { zoxide.insert(custom.appending(path: "db.zo"), at: 0) }
        for file in uniqued(zoxide) {
            guard let data = read(file, limit: databaseLimit) else { continue }
            for (path, rank, last) in parseZoxide(data) { activity.add(path, home: home, weight: rank, last: last) }
            break
        }
        let z = environment["_Z_DATA"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appending(path: ".z")
        if let data = read(z, limit: databaseLimit) {
            for (path, rank, last) in parseZ(data) { activity.add(path, home: home, weight: rank, last: last) }
        }
        var histories: [(URL, HistoryKind)] = [(home.appending(path: ".zsh_history"), .zsh), (home.appending(path: ".bash_history"), .bash)]
        if let custom = environment["HISTFILE"], !custom.isEmpty {
            let file = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            histories.insert((file, file.lastPathComponent.contains("zsh") ? .zsh : .bash), at: 0)
        }
        let fishData = dir("XDG_DATA_HOME") ?? home.appending(path: ".local/share")
        histories.append((fishData.appending(path: "fish/fish_history"), .fish))
        var seenFiles = Set<String>()
        for (file, kind) in histories where seenFiles.insert(file.standardizedFileURL.path).inserted {
            guard let data = readTail(file, limit: historyTail) else { continue }
            // A history line with no time (bash without HISTTIMEFORMAT) counts as a visit as
            // old as the file's last write: the file is append-only, so that bounds it.
            let written = (try? file.blockingResourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            for (path, time) in parseHistory(data, kind: kind) {
                activity.add(path, home: home, weight: 1, last: time ?? min(written, now))
            }
        }
        return activity
    }

    /// Adds a visit of `path`, absolute or starting with `~`; anything else is ignored.
    mutating func add(_ path: String, home: URL, weight: Double, last: Date) {
        guard let id = Self.standardized(path, home: home) else { return }
        var entry = visits[id] ?? Visits(weight: 0, last: .distantPast)
        entry.weight = min(Self.maxWeight, entry.weight + max(0, weight))
        entry.last = max(entry.last, last)
        visits[id] = entry
    }

    static func standardized(_ path: String, home: URL) -> String? {
        var text = path.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        if text == "~" || text.hasPrefix("~/") { text = home.path + text.dropFirst() }
        guard text.hasPrefix("/"), !text.contains("$"), !text.contains("*") else { return nil }
        let id = URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL.path
        return id.count > 1 ? id : nil
    }

    // MARK: zoxide

    /// zoxide's database (version 3): a little-endian `u32` version, then a
    /// bincode `Vec` of `{path: String, rank: f64, last_accessed: u64}`, every
    /// length a little-endian `u64`. Anything else, or a cut-off file, ends the read.
    static func parseZoxide(_ data: Data) -> [(String, Double, Date)] {
        var reader = ByteReader(data)
        guard reader.u32() == 3, let count = reader.u64(), count < 1_000_000 else { return [] }
        var dirs: [(String, Double, Date)] = []
        for _ in 0..<count {
            guard let length = reader.u64(), length <= 4096, let bytes = reader.bytes(Int(length)),
                  let path = String(bytes: bytes, encoding: .utf8),
                  let rankBits = reader.u64(), let last = reader.u64() else { break }
            let rank = Double(bitPattern: rankBits)
            guard rank.isFinite else { continue }
            dirs.append((path, rank, Date(timeIntervalSince1970: TimeInterval(min(last, 1 << 40)))))
        }
        return dirs
    }

    // MARK: z

    /// z's `path|rank|epoch` lines.
    static func parseZ(_ data: Data) -> [(String, Double, Date)] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 3, let rank = Double(fields[fields.count - 2]), rank.isFinite,
                  let epoch = TimeInterval(fields[fields.count - 1]) else { return nil }
            let path = fields.dropLast(2).joined(separator: "|")
            return (path, rank, Date(timeIntervalSince1970: epoch))
        }
    }

    // MARK: Shell history

    enum HistoryKind { case zsh, bash, fish }

    /// Each `cd` or `pushd` to one absolute or `~` path, with its time when the history has one.
    static func parseHistory(_ data: Data, kind: HistoryKind) -> [(String, Date?)] {
        // zsh's metafied bytes (0x83 then the byte XOR 0x20) only spell non-ASCII; drop the marker.
        let text = String(decoding: kind == .zsh ? unmetafied(data) : data, as: UTF8.self)
        var found: [(String, Date?)] = []
        var pendingTime: Date?
        var fishCommand: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            switch kind {
            case .zsh:
                // Extended history: `: <epoch>:<duration>;<command>`.
                if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                    let stamp = line[line.index(line.startIndex, offsetBy: 2)..<semicolon].split(separator: ":").first
                    let time = stamp.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
                    if let path = cdTarget(String(line[line.index(after: semicolon)...])) { found.append((path, time)) }
                } else if let path = cdTarget(line) {
                    found.append((path, nil))
                }
            case .bash:
                // HISTTIMEFORMAT writes `#<epoch>` before its command.
                if line.hasPrefix("#"), let epoch = TimeInterval(line.dropFirst()) {
                    pendingTime = Date(timeIntervalSince1970: epoch)
                    continue
                }
                if let path = cdTarget(line) { found.append((path, pendingTime)) }
                pendingTime = nil
            case .fish:
                // `- cmd: <command>` then `  when: <epoch>`.
                if line.hasPrefix("- cmd: ") {
                    if let command = fishCommand, let path = cdTarget(command) { found.append((path, nil)) }
                    fishCommand = String(line.dropFirst(7))
                } else if line.hasPrefix("  when: "), let command = fishCommand {
                    let time = TimeInterval(line.dropFirst(8).trimmingCharacters(in: .whitespaces)).map(Date.init(timeIntervalSince1970:))
                    if let path = cdTarget(command) { found.append((path, time)) }
                    fishCommand = nil
                }
            }
        }
        if let command = fishCommand, let path = cdTarget(command) { found.append((path, nil)) }
        return found
    }

    /// The folder of a `cd <path>` or `pushd <path>` command (the first one
    /// of a `&&` or `;` chain), when it is absolute or starts with `~`.
    static func cdTarget(_ command: String) -> String? {
        let first = command.split(separator: ";").first.map(String.init) ?? command
        let segment = (first.components(separatedBy: "&&").first ?? first).trimmingCharacters(in: .whitespaces)
        let verb = segment.prefix { !$0.isWhitespace }
        guard verb == "cd" || verb == "pushd" else { return nil }
        let rest = segment.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.hasPrefix("-") else { return nil }
        let unescaped = rest.replacingOccurrences(of: "\\ ", with: " ")
        return unescaped.hasPrefix("/") || unescaped.hasPrefix("~") || unescaped.hasPrefix("\"") || unescaped.hasPrefix("'")
            ? unescaped : nil
    }

    static func unmetafied(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var out = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta { out.append(byte ^ 0x20); meta = false } else if byte == 0x83 { meta = true } else { out.append(byte) }
        }
        return out
    }

    // MARK: Files

    private static func uniqued(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func read(_ file: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    /// The last `limit` bytes of `file`, from its first whole line.
    static func readTail(_ file: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(limit) ? end - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.read(upToCount: limit) else { return nil }
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[data.index(after: newline)...] }
        return Data(data)
    }
}

/// Little-endian reads over a byte buffer that stop at its end.
private nonisolated struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func u32() -> UInt32? {
        bytes(4).map { $0.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    }

    mutating func u64() -> UInt64? {
        bytes(8).map { $0.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    }
}
