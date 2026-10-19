import CmuxNextSettings
import Foundation

/// Cached health rows for display. Execution plans stay with the native owner.
nonisolated enum AgentCLIUpdates {
    /// The rows of a `_acpmux/harness/health` answer by harness id; nil when it is not one.
    static func rows(_ data: Data) -> [String: JSONValue]? {
        guard let rows = (try? JSONValue.parse(data))?["harnesses"]?.arrayValue else { return nil }
        return Dictionary(rows.compactMap { row in row["id"]?.stringValue.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

}
