import Foundation

/// The journal's files: NDJSON segments of ``ErrorEntry`` snapshots, newest line per
/// fingerprint wins. Appends go to the newest segment; once it passes the size limit the live
/// table is written to a new segment (temp file, then rename) and every older segment is
/// deleted, so disk use stays below about twice the limit. Owned by ``ErrorJournal``, which
/// serializes every call.
struct ErrorSegmentStore {
    let directory: URL
    let segmentBytes: Int
    private let files = FileManager()
    private var current: URL?
    private var currentBytes = 0
    private var sequence = 0

    init(directory: URL, segmentBytes: Int) {
        self.directory = directory
        self.segmentBytes = segmentBytes
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

    /// Reads every segment, oldest first; a line that does not decode (a torn last write) is skipped.
    mutating func load() -> [String: ErrorEntry] {
        var table: [String: ErrorEntry] = [:]
        let decoder = JSONDecoder()
        let all = segments()
        for (_, url) in all {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let entry = try? decoder.decode(ErrorEntry.self, from: Data(line)) { table[entry.fingerprint] = entry }
            }
        }
        if let last = all.last {
            current = last.url
            sequence = last.sequence
            currentBytes = ((try? files.attributesOfItem(atPath: last.url.path)[.size]) as? Int) ?? 0
        }
        return table
    }

    /// Appends `changed`; compacts `all()` into a new segment first when the newest one is full.
    mutating func write(changed: [ErrorEntry], all: () -> [ErrorEntry]) throws {
        guard !changed.isEmpty else { return }
        let data = try Self.lines(changed)
        if current == nil || currentBytes + data.count > segmentBytes {
            try compact(all())
            return
        }
        guard let current, let handle = try? FileHandle(forWritingTo: current) else {
            try compact(all())
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        currentBytes += data.count
    }

    /// Writes `entries` as the only live segment and deletes the older ones.
    mutating func compact(_ entries: [ErrorEntry]) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = segments()
        sequence = (old.last?.sequence ?? sequence) + 1
        let name = Self.prefix + String(format: "%06d", sequence) + Self.suffix
        let url = directory.appendingPathComponent(name)
        let data = try Self.lines(entries)
        try data.write(to: url, options: .atomic)
        for (_, oldURL) in old where oldURL != url { try? files.removeItem(at: oldURL) }
        current = url
        currentBytes = data.count
    }

    /// Bytes of every segment on disk.
    func diskBytes() -> Int {
        segments().reduce(0) { sum, segment in
            sum + (((try? files.attributesOfItem(atPath: segment.url.path)[.size]) as? Int) ?? 0)
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
}
