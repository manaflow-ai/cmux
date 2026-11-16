import Foundation
import os

/// The device's own connectivity log: one JSON line per kept record, in a file that rolls to
/// `<name>.1` when it passes ``maxBytes`` (so at most twice that is on disk). It is read from
/// the app (Settings, the debug socket, a support export) and never leaves the device by itself.
///
/// ``ConnectivityTelemetry`` writes through one instance from its drain task; a reader (Copy
/// Logs) may make its own instance for the same file and only read.
public final class ConnectivityJournal: Sendable {
    public let url: URL
    public let maxBytes: Int
    /// The open file and its size; every write and roll runs under it.
    private struct FileState: Sendable {
        var handle: FileHandle?
        var size = 0
    }

    // lint:allow lock - appends come from the recorder's one drain task; the lock makes the
    // class Sendable and serializes a reader's flush with a write, never contended in practice.
    private let file = OSAllocatedUnfairLock(initialState: FileState())

    /// - Parameters:
    ///   - url: The current file; the rolled one is beside it with `.1` added.
    ///   - maxBytes: When the current file passes this, it rolls.
    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
    }

    deinit { file.withLock { try? $0.handle?.close() } }

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
        file.withLock { state in
            if state.size > 0, state.size + line.count > maxBytes { roll(&state) }
            guard let handle = open(&state) else { return }
            do {
                try handle.write(contentsOf: line)
                state.size += line.count
            } catch {
                try? handle.close()
                state.handle = nil
            }
        }
    }

    /// Both files' lines, oldest first.
    public func contents() -> String {
        file.withLock { _ = try? $0.handle?.synchronize() }
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
        file.withLock { state in
            try? state.handle?.close()
            state = FileState()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    private func open(_ state: inout FileState) -> FileHandle? {
        if let handle = state.handle { return handle }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        state.size = Int((try? opened.seekToEnd()) ?? 0)
        state.handle = opened
        return opened
    }

    private func roll(_ state: inout FileState) {
        try? state.handle?.close()
        state = FileState()
        let manager = FileManager.default
        try? manager.removeItem(at: previousURL)
        try? manager.moveItem(at: url, to: previousURL)
    }
}
