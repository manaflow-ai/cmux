import CmuxNextCompat
public import Foundation

/// `auto-shadow.jsonl` in this build's acpmux home (RFD 0072 stage 1): one line per Auto pass where the host budget's
/// verdict alone would move a chat (Rust's `verdict::shadow_line`). It starts over past ``cap`` so a long over-budget
/// spell cannot grow it without bound. Call it off the main thread.
public struct CloudPlaceShadowLog {
    public init() {}
    public static let cap = 4 << 20

    /// Appends `line` to `auto-shadow.jsonl` in the acpmux `home`, off the caller's thread.
    public nonisolated static func appendDetached(_ line: String, home: URL) {
        let file = home.appendingPathComponent("auto-shadow.jsonl", isDirectory: false)
        // task-owner: one append off the main thread; it writes the line and ends.
        Task.detached(priority: .utility) { CloudPlaceShadowLog.append(line, to: file) }
    }

    public nonisolated static func append(_ line: String, to file: URL) {
        let data = Data((line + "\n").utf8)
        let size = (try? file.blockingResourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < cap, let handle = try? FileHandle(forWritingTo: file) else {
            try? data.blockingWrite(to: file, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.blockingWrite(contentsOf: data)
    }
}
