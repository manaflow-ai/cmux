public import Foundation
import CmuxFoundation

extension GrokSessionResolver {
    /// The display metadata extracted from a single Grok `chat_history.jsonl`
    /// file: the conversation title, the model and approval/sandbox modes the
    /// session ran under, and the git branch it was started on. Every field is
    /// optional (and the title defaults to empty) because a session file may
    /// stop before any given field is observed.
    public struct GrokSessionMetadata: Sendable {
        /// The conversation title, or `""` when none was found.
        public var title: String = ""
        /// The model the session used, when recorded.
        public var model: String?
        /// The approval/permission mode the session ran under, when recorded.
        public var permissionMode: String?
        /// The sandbox mode the session ran under, when recorded.
        public var sandboxMode: String?
        /// The git branch the session was started on, when recorded.
        public var branch: String?

        /// Creates an empty metadata value.
        public init() {}
    }

    /// Scans a Grok `chat_history.jsonl` file for its display metadata, reading
    /// at most the first 512 KB and stopping early once every stable field
    /// (title, model, permission mode, sandbox mode) is filled and the branch is
    /// either found or a bounded probe window has elapsed.
    ///
    /// - Parameter url: The `chat_history.jsonl` file to scan.
    /// - Returns: The metadata observed; fields that never appeared stay `nil`
    ///   (or `""` for the title).
    public func extractGrokSessionMetadata(url: URL) -> GrokSessionMetadata {
        var metadata = GrokSessionMetadata()
        let fieldParser = AgentSessionFieldParser()
        let scanner = RipgrepFileScanner()
        var remainingBranchProbeLines: Int?
        scanner.forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
            if metadata.title.isEmpty {
                metadata.title = fieldParser.grokTitle(in: object) ?? ""
            }
            if metadata.model == nil {
                metadata.model = fieldParser.firstString(in: object, keys: ["model", "modelId", "modelID", "model_id"])
                    ?? fieldParser.firstString(
                        in: object["message"] as? [String: Any] ?? [:],
                        keys: ["model", "modelId", "modelID", "model_id"]
                    )
            }
            if metadata.permissionMode == nil {
                metadata.permissionMode = fieldParser.firstString(
                    in: object,
                    keys: ["permissionMode", "permission_mode", "approvalPolicy", "approval_policy"]
                )
            }
            if metadata.sandboxMode == nil {
                metadata.sandboxMode = fieldParser.firstString(
                    in: object,
                    keys: ["sandboxMode", "sandbox_mode", "sandbox"]
                )
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = fieldParser.firstString(in: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = fieldParser.firstString(in: object, keys: ["gitBranch", "branch"])
            }
            let hasStableMetadata = !metadata.title.isEmpty
                && metadata.model != nil
                && metadata.permissionMode != nil
                && metadata.sandboxMode != nil
            guard hasStableMetadata else { return false }
            guard metadata.branch == nil else { return true }
            remainingBranchProbeLines = (remainingBranchProbeLines ?? 32) - 1
            return (remainingBranchProbeLines ?? 0) <= 0
        }
        return metadata
    }
}
