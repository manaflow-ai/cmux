import Foundation

/// The device's own connectivity log: one JSON line per kept record, in a file that rolls to
/// `<name>.1` when it passes ``maxBytes`` (so at most twice that is on disk). It is read from
/// the app (Settings, the debug socket, a support export) and never leaves the device by itself.
///
/// Not thread-safe: ``ConnectivityTelemetry`` writes through one instance from its drain task
/// only. A reader (Copy Logs) makes its own instance for the same file and only reads.
public final class ConnectivityJournal: @unchecked Sendable {
    public let url: URL
    public let maxBytes: Int
    private var handle: FileHandle?
    private var size: Int = 0

    /// - Parameters:
    ///   - url: The current file; the rolled one is beside it with `.1` added.
    ///   - maxBytes: When the current file passes this, it rolls.
    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
    }

    deinit { try? handle?.close() }

    /// The rolled file.
    public var previousURL: URL { url.appendingPathExtension("1") }

    /// The standard journal of an app: `connectivity.jsonl` in `directory`.
    public convenience init(directory: URL, maxBytes: Int = 1_000_000) {
        self.init(url: directory.appendingPathComponent("connectivity.jsonl"), maxBytes: maxBytes)
    }

    /// The app container's journal: `Library/Application Support/Connectivity/connectivity.jsonl`
    /// (the iPhone app; a Mac build passes its own per-build directory instead).
    public static func applicationSupport(maxBytes: Int = 1_000_000) -> ConnectivityJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ConnectivityJournal(directory: base.appendingPathComponent("Connectivity", isDirectory: true), maxBytes: maxBytes)
    }

    /// Appends one record. A write that fails is dropped: the journal never stops the app.
    public func append(_ record: ConnectivityRecord) {
        let line = Data((record.jsonLine() + "\n").utf8)
        guard let handle = openHandle() else { return }
        if size > 0, size + line.count > maxBytes {
            roll()
            guard let fresh = openHandle() else { return }
            write(line, to: fresh)
            return
        }
        write(line, to: handle)
    }

    /// Both files' lines, oldest first.
    public func contents() -> String {
        try? handle?.synchronize()
        let previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return previous + current
    }

    /// The kept records, oldest first.
    public func records() -> [ConnectivityRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return (try? ConnectivityRecord.timestampStyle.parse(text)) ?? Date(timeIntervalSince1970: 0)
        }
        return contents().split(separator: "\n").compactMap { line in
            try? decoder.decode(ConnectivityRecord.self, from: Data(line.utf8))
        }
    }

    /// Whether either file holds a record of the cmux team.
    public func holdsTeamRecords() -> Bool {
        contents().contains(#""tier":"team""#)
    }

    /// Removes both files (the account changed: the next one never reads the last one's log).
    public func clear() {
        try? handle?.close()
        handle = nil
        size = 0
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: previousURL)
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        size = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }

    private func write(_ line: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: line)
            size += line.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func roll() {
        try? handle?.close()
        handle = nil
        size = 0
        let manager = FileManager.default
        try? manager.removeItem(at: previousURL)
        try? manager.moveItem(at: url, to: previousURL)
    }
}
