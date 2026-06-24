import Foundation
import os

/// DEBUG diagnostic log for the chat lab. Writes structured, timestamped lines
/// to `Documents/chatlab.log` (pulled off a device with
/// `devicectl device copy from --domain-type appDataContainer
/// --domain-identifier dev.cmux.ios.lab --source Documents/chatlab.log`) and
/// mirrors to `os_log`.
///
/// File writes run on a background actor so the MainActor, and specifically the
/// scroll/keyboard paths we are trying to measure, never block on I/O. The hot
/// per-frame path is deliberately NOT logged here; the controller logs state
/// transitions and a per-episode inset-write count instead, so the file stays
/// small and readable and the act of logging cannot itself cause jank.
public final class ChatLabLog: Sendable {
    public static let shared = ChatLabLog()

    private let logger = Logger(subsystem: "dev.cmux.ios.lab", category: "chatlab")
    private let writer = FileWriter()
    private let clock = Clock()

    private init() {}

    /// Truncate the file and write a session header so each launch starts clean.
    public func startSession(_ info: String) {
        Task { await writer.reset() }
        log("=== session: \(info) ===")
    }

    public func log(_ message: String) {
        let line = "\(clock.elapsedMilliseconds()) \(message)"
        logger.info("\(line, privacy: .public)")
        Task { await writer.append(line) }
    }

    /// A loud, easy-to-grep marker (the JANK button).
    public func mark(_ label: String) {
        log("########## \(label) ##########")
    }

    /// Monotonic-ish wall clock from process start, for relative timestamps.
    private struct Clock: Sendable {
        let start = Date()
        func elapsedMilliseconds() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
    }

    private actor FileWriter {
        private let url: URL?
        private var handle: FileHandle?

        init() {
            url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("chatlab.log")
        }

        func reset() {
            try? handle?.close()
            handle = nil
            guard let url else { return }
            try? FileManager.default.removeItem(at: url)
        }

        func append(_ line: String) {
            guard let url else { return }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
