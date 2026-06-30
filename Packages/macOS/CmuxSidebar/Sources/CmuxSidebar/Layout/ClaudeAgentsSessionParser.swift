public import Foundation

/// Parses the JSON array printed by `claude agents --json` (optionally with
/// `--all`) into ``CustomSidebarAgentSnapshot`` values for the custom-sidebar
/// interpreter context.
///
/// Parsing is deliberately lenient: a payload that fails to decode (claude not
/// installed, an error written to stdout, a schema change) yields an empty
/// array rather than throwing, and individual entries missing a `cwd` are
/// dropped instead of failing the whole batch. This keeps the sidebar render
/// resilient — a bad poll simply shows no agents instead of breaking.
public enum ClaudeAgentsSessionParser {
    /// Decodes `claude agents --json` stdout into agent snapshots. Returns an
    /// empty array on any decode failure.
    public static func parse(_ data: Data) -> [CustomSidebarAgentSnapshot] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries.compactMap { $0.snapshot }
    }

    /// A lenient mirror of one `claude agents --json` array element. Every field
    /// is optional so a single malformed or partial entry cannot fail the whole
    /// decode; entries without a `cwd` are dropped when projecting.
    private struct Entry: Decodable {
        let id: String?
        let cwd: String?
        let kind: String?
        let name: String?
        let sessionId: String?
        let state: String?
        let status: String?
        let pid: Int?
        let startedAt: Double?
        let waitingFor: String?

        var snapshot: CustomSidebarAgentSnapshot? {
            guard let cwd, !cwd.isEmpty else { return nil }
            return CustomSidebarAgentSnapshot(
                id: id,
                cwd: cwd,
                kind: kind ?? "",
                name: name,
                sessionId: sessionId,
                state: state,
                status: status,
                pid: pid,
                startedAt: startedAt.map { Int($0) },
                waitingFor: waitingFor
            )
        }
    }
}
