import Darwin
import Foundation

/// Loads recorded Codex permissions away from the hook caller's executor.
public actor CodexResumePermissionEvidenceReader {
    private let maximumBytes: Int

    /// Creates an evidence reader with a bounded transcript search window.
    ///
    /// - Parameter maximumBytes: Maximum tail bytes to inspect; defaults to 4 MiB.
    public init(maximumBytes: Int = 4 * 1024 * 1024) {
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Returns the newest usable recorded permissions before a capture time.
    ///
    /// - Parameters:
    ///   - transcriptPath: The transcript file to read; a leading tilde is expanded.
    ///   - capturedAt: Exclusive upper bound for the turn timestamp.
    /// - Returns: Permission flags, or an empty array if no complete eligible record is available.
    public func permissionArguments(
        transcriptPath: String,
        before capturedAt: TimeInterval
    ) -> [String] {
        let expandedPath = (transcriptPath as NSString).expandingTildeInPath
        let descriptor = open(expandedPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            return []
        }
        defer { try? handle.close() }
        guard let endOffset = try? handle.seekToEnd() else { return [] }
        let policy = CodexResumePermissionPolicy()
        var offset = endOffset
        var pending = Data()
        while offset > 0 {
            let byteCount = min(UInt64(64 * 1024), offset)
            offset -= byteCount
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return []
            }
            guard let chunk = try? handle.read(upToCount: Int(byteCount)) else { return [] }
            pending.insert(contentsOf: chunk, at: pending.startIndex)
            while let newline = pending.lastIndex(of: 0x0A) {
                let lineStart = pending.index(after: newline)
                let line = Data(pending[lineStart...])
                pending.removeSubrange(newline...)
                if let arguments = policy.permissionArguments(
                    from: line,
                    before: capturedAt
                ) {
                    return arguments
                }
            }
        }
        return policy.permissionArguments(from: pending, before: capturedAt) ?? []
    }
}
