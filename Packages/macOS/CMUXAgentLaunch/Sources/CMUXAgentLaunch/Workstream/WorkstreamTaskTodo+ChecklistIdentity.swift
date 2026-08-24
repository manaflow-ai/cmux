import Foundation

extension WorkstreamTaskTodo {
    /// Returns a stable identity for this task inside one agent workstream.
    /// Task ids are only unique within a session, so the workstream id is part
    /// of the digest before it is mapped to a UUID.
    public func stableChecklistItemId(workstreamId: String) -> UUID {
        Self.checklistItemId(workstreamId: workstreamId, taskId: id)
    }

    /// Returns the stable identity for a task that is no longer in the current
    /// list (for example, a task removed by `TaskUpdate`).
    public static func checklistItemId(workstreamId: String, taskId: String) -> UUID {
        var bytes = Array(repeating: UInt8(0), count: 16)
        for (index, byte) in Data("cmux.workstream.todo\u{0}\(workstreamId)\u{0}\(taskId)".utf8).enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &+ byte &+ UInt8(truncatingIfNeeded: index * 17)
            bytes[(slot + 5) % bytes.count] ^= byte &* 31
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
