import Foundation

/// Matches Codex rollout JSONL files to a confirmed session id.
///
/// Codex writes rollout files under `.codex/sessions` with a `session_meta`
/// first line. When that metadata is present it is the authority; the filename
/// suffix is used only for metadata-free legacy files.
public struct CodexTranscriptIdentityMatcher: Sendable {
    /// Creates a Codex transcript identity matcher.
    public init() {}

    /// Returns whether a rollout file belongs to the provided session id.
    ///
    /// - Parameters:
    ///   - url: The candidate rollout JSONL file URL.
    ///   - sessionID: The confirmed Codex session id for the pane/session.
    /// - Returns: `true` only when the rollout is bound to `sessionID`.
    public func transcript(at url: URL, matchesSessionID sessionID: String) -> Bool {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else { return false }
        if let sessionMetaID = sessionMetaID(at: url) {
            return sessionMetaID.lowercased() == normalizedSessionID
        }
        let filename = url.lastPathComponent.lowercased()
        return filename == "\(normalizedSessionID).jsonl"
            || filename.hasSuffix("-\(normalizedSessionID).jsonl")
    }

    private func sessionMetaID(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              !data.isEmpty else {
            return nil
        }
        let lineData: Data
        if let newline = data.firstIndex(of: 0x0A) {
            lineData = Data(data[..<newline])
        } else {
            lineData = data
        }
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String else {
            return nil
        }
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalized(_ sessionID: String) -> String {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
