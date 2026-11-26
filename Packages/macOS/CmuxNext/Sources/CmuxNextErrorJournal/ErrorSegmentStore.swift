import Foundation

/// The journal's files: NDJSON segments, newest line per fingerprint wins. Appends go to the newest
/// segment; a compaction writes a new segment (temp file, then rename) and deletes every older one,
/// so disk use stays below about twice the limit. The lines and when to append or compact are
/// Rust's (`cmux-error-journal`); this store only reads and writes bytes. Owned by ``ErrorJournal``,
/// which serializes every call.
struct ErrorSegmentStore {
    /// How one write went.
    struct Outcome {
        /// Whether the bytes reached disk (for a compaction, the new segment).
        var written: Bool
        /// The bytes written.
        var bytes: Int
        /// The first error: the write's, or (a written compaction) removing an old segment.
        var error: String?
    }

    let directory: URL
    private let files = FileManager()
    private var current: URL?
    private var sequence = 0

    init(directory: URL) {
        self.directory = directory
        try? Self.protectDirectory(directory)
    }

    private static let prefix = "segment-"
    private static let suffix = ".ndjson"

    private func segments() -> [(sequence: Int, url: URL)] {
        let names = (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix(Self.prefix), name.hasSuffix(Self.suffix),
                  let number = Int(name.dropFirst(Self.prefix.count).dropLast(Self.suffix.count)) else { return nil }
            return (number, directory.appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }
    }

    /// Every segment's text, oldest first, and the size of the newest (nil when there is none).
    mutating func load() -> (segments: [String], currentBytes: Int?) {
        var texts: [String] = []
        let all = segments()
        for (_, url) in all {
            try? Self.protectFile(url)
            guard let data = try? Data(contentsOf: url) else { continue }
            texts.append(String(decoding: data, as: UTF8.self))
        }
        guard let last = all.last else { return (texts, nil) }
        current = last.url
        sequence = last.sequence
        return (texts, ((try? files.attributesOfItem(atPath: last.url.path)[.size]) as? Int) ?? 0)
    }

    /// Appends `data` to the newest segment; nil when there is none or it does not open.
    func append(_ data: Data) -> Outcome? {
        guard let current, let handle = try? FileHandle(forWritingTo: current) else { return nil }
        defer { try? handle.close() }
        do {
            try Self.protectFile(current)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return Outcome(written: true, bytes: data.count)
        } catch {
            return Outcome(written: false, bytes: 0, error: String(describing: error))
        }
    }

    /// Writes `data` as the only live segment and deletes the older ones.
    mutating func compact(_ data: Data) -> Outcome {
        let old = segments()
        let url: URL
        do {
            try Self.protectDirectory(directory)
            sequence = (old.last?.sequence ?? sequence) + 1
            url = directory.appendingPathComponent(Self.prefix + String(format: "%06d", sequence) + Self.suffix)
            try data.write(to: url, options: .atomic)
            try Self.protectFile(url)
        } catch {
            return Outcome(written: false, bytes: 0, error: String(describing: error))
        }
        current = url
        var firstRemovalError: (any Error)?
        for (_, oldURL) in old where oldURL != url {
            do { try files.removeItem(at: oldURL) }
            catch { if firstRemovalError == nil { firstRemovalError = error } }
        }
        return Outcome(written: true, bytes: data.count, error: firstRemovalError.map { String(describing: $0) })
    }

    /// Bytes of every segment on disk.
    func diskBytes() -> Int {
        segments().reduce(0) { sum, segment in
            sum + (((try? files.attributesOfItem(atPath: segment.url.path)[.size]) as? Int) ?? 0)
        }
    }

    static func protectDirectory(_ url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func protectFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
