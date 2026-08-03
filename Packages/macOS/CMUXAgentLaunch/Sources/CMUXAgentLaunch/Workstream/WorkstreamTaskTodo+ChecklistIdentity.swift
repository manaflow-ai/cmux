import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

extension WorkstreamTaskTodo {
    /// A stable workspace-checklist identity for this todo inside
    /// `workstreamId`.
    ///
    /// Agent task ids are per-session counters (`"1"`, `"2"`, …) while the
    /// workspace checklist is keyed by `UUID`, so the pair is hashed into a
    /// deterministic UUID. Deriving it (instead of keeping a side table) means
    /// the same task keeps its checklist row across app restarts and across
    /// every entrypoint that syncs the list, and scoping it by workstream
    /// keeps two concurrent agents in one workspace from colliding on the
    /// shared `"1"`, `"2"` numbering.
    ///
    /// - Parameter workstreamId: The owning workstream (agent session) id.
    /// - Returns: A deterministic RFC 4122 UUID for this `(workstream, task)`.
    public func stableChecklistItemId(workstreamId: String) -> UUID {
        workstreamChecklistItemId(workstreamId: workstreamId, taskId: id)
    }
}

/// The deterministic checklist identity for one agent task id.
///
/// Exposed separately from ``WorkstreamTaskTodo/stableChecklistItemId(workstreamId:)``
/// so callers can derive the identity of a task they no longer hold (for
/// example, retiring rows for tasks the agent has deleted).
///
/// - Parameters:
///   - workstreamId: The owning workstream (agent session) id.
///   - taskId: The agent's task id.
/// - Returns: A deterministic RFC 4122 UUID for this `(workstream, task)`.
public func workstreamChecklistItemId(workstreamId: String, taskId: String) -> UUID {
    derivedChecklistUUID(from: "cmux.workstream.todo\u{0}\(workstreamId)\u{0}\(taskId)")
}

private func derivedChecklistUUID(from seed: String) -> UUID {
    let data = Data(seed.utf8)
    var bytes: [UInt8]
    #if canImport(CryptoKit)
    bytes = Array(SHA256.hash(data: data).prefix(16))
    #else
    bytes = Array(repeating: 0, count: 16)
    for (index, byte) in data.enumerated() {
        bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index)
    }
    #endif
    // RFC 4122 version 4 / variant bits so the value is a well-formed UUID.
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
