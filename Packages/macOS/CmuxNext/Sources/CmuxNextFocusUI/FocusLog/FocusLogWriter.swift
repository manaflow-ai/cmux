public import Foundation

/// Appends focus log lines to `focus-log.jsonl`, symbolicating each entry's stack first, off the
/// main thread. The file rolls over to `focus-log.1.jsonl` past ``rolloverBytes``, so the log
/// keeps at most twice that on disk.
public actor FocusLogWriter {
    /// The size a log file grows to before it rolls over.
    public static let rolloverBytes = 4 << 20

    /// The log file (nil: no Library folder, nothing is written).
    public nonisolated let url: URL?
    private let symbolicate: @Sendable ([UInt]) -> [String]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// - Parameters:
    ///   - directory: The log folder: `~/Library/Logs/cmux-next/<tag or release>` in the app,
    ///     a temporary folder in tests.
    ///   - symbolicate: Return addresses to frame descriptions (`StackSymbolicator` in the
    ///     app, which names release-build frames through the bundled symbol map).
    public init(directory: URL?, symbolicate: @escaping @Sendable ([UInt]) -> [String]) {
        url = directory?.appending(path: "focus-log.jsonl")
        self.symbolicate = symbolicate
    }

    /// The app's log folder for a build `tag`: `~/Library/Logs/cmux-next/<tag>`, `release` for
    /// untagged builds (NIGHTLY included), beside the desync reports.
    public static func folder(tag: String?) -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appending(path: "Logs/cmux-next/\(tag ?? "release")", directoryHint: .isDirectory)
    }

    /// Symbolicates `addresses` into `entry.stack` and appends the entry as one JSON line.
    public func append(_ entry: FocusLogEntry, addresses: [UInt]) {
        guard let url else { return }
        var entry = entry
        if !addresses.isEmpty { entry.stack = symbolicate(addresses) }
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let files = FileManager.default
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size + line.count > Self.rolloverBytes {
                let rolled = url.deletingLastPathComponent().appending(path: "focus-log.1.jsonl")
                try? files.removeItem(at: rolled)
                try files.moveItem(at: url, to: rolled)
            }
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics only: a full disk or a removed folder drops the line.
        }
    }
}
