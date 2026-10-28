import Foundation
import CmuxNextCompat

/// The journal's files: NDJSON segments of ``ErrorEntry`` snapshots, newest line per
/// fingerprint wins. Appends go to the newest segment; once it passes the size limit the live
/// table is written to a new segment (temp file, then rename) and every older segment is
/// deleted, so disk use stays below about twice the limit. Owned by ``ErrorJournal``, which
/// serializes every call.
struct ErrorSegmentStore {
    let directory: URL
    let segmentBytes: Int
    private var current: URL?
    private var currentBytes = 0
    private var sequence = 0
    private var cleanupPending = false

    init(directory: URL, segmentBytes: Int) {
        self.directory = directory
        self.segmentBytes = segmentBytes
        try? Self.protectDirectory(directory)
    }

    private static let prefix = "segment-"
    private static let suffix = ".ndjson"

    private func segments() -> [(sequence: Int, url: URL)] {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix(Self.prefix), name.hasSuffix(Self.suffix),
                  let number = Int(name.dropFirst(Self.prefix.count).dropLast(Self.suffix.count), radix: 10) else { return nil }
            return (number, directory.appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }
    }

    /// Reads every snapshot, oldest first; a line that does not decode (a torn last write) is skipped.
    ///
    /// The journal canonicalizes every snapshot before choosing the newest one
    /// per fingerprint, so a secret in shadowed history still triggers compaction.
    mutating func load() -> [ErrorEntry] {
        var entries: [ErrorEntry] = []
        let decoder = JSONDecoder()
        let all = segments()
        for (_, url) in all {
            try? Self.protectFile(url)
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let entry = try? decoder.decode(ErrorEntry.self, from: Data(line)) { entries.append(entry) }
            }
        }
        if let last = all.last {
            current = last.url
            sequence = last.sequence
            currentBytes = ((try? FileManager.checked.attributesOfItem(atPath: last.url.path)[.size]) as? Int) ?? 0
        }
        return entries
    }

    /// Appends `changed`; compacts `all()` into a new segment first when the newest one is full.
    mutating func write(changed: [ErrorEntry], all: () -> [ErrorEntry]) throws {
        guard !changed.isEmpty else { return }
        if cleanupPending {
            try compact(all())
            return
        }
        let data = try Self.lines(changed)
        if current == nil || currentBytes + data.count > segmentBytes {
            try compact(all())
            return
        }
        guard let current, let handle = try? FileHandle.blockingForWriting(to: current) else {
            try compact(all())
            return
        }
        defer { try? handle.close() }
        try Self.protectFile(current)
        try handle.blockingSeekToEnd()
        try handle.blockingWrite(contentsOf: data)
        currentBytes += data.count
    }

    /// Writes `entries` as the only live segment and deletes the older ones.
    mutating func compact(_ entries: [ErrorEntry]) throws {
        try Self.protectDirectory(directory)
        let old = segments()
        sequence = (old.last?.sequence ?? sequence) + 1
        let name = Self.prefix + String(format: "%06d", sequence) + Self.suffix
        let url = directory.appendingPathComponent(name)
        let data = try Self.lines(entries)
        try data.write(to: url, options: .atomic)
        try Self.protectFile(url)
        current = url
        currentBytes = data.count
        var firstRemovalError: (any Error)?
        for (_, oldURL) in old where oldURL != url {
            do { try FileManager.checked.removeItem(at: oldURL) }
            catch { if firstRemovalError == nil { firstRemovalError = error } }
        }
        if let firstRemovalError {
            cleanupPending = true
            throw firstRemovalError
        }
        cleanupPending = false
    }

    /// Bytes of every segment on disk.
    func diskBytes() -> Int {
        segments().reduce(0) { sum, segment in
            sum + (((try? FileManager.checked.attributesOfItem(atPath: segment.url.path)[.size]) as? Int) ?? 0)
        }
    }

    private static func lines(_ entries: [ErrorEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    static func protectDirectory(_ url: URL) throws {
        try FileManager.checked.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.checked.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func protectFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
