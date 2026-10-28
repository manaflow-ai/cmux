import Foundation

/// The hidden string-list setting keeps its wire stamp in its first member. The config-file actor
/// compares and publishes together, so delayed writes cannot replace a newer persisted order.
nonisolated enum InspectorOrderRevision {
    static let path = ["agentPane", "display", "inspector", "order"]
    static let prefix = "@cmux-order/v1/"
    static func stamp(_ value: JSONValue?) -> (time: Int64, writer: String)? {
        guard let value, case .array(let values) = value, let first = values.first?.stringValue,
              first.hasPrefix(prefix) else { return nil }
        let parts = first.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let time = Int64(parts[0]), time >= 0, time < 9_007_199_254_740_991 else { return nil }
        return (time, String(parts[1]))
    }
    static func resolving(_ proposed: JSONValue?, over stored: JSONValue?, now: Int64, writer: String) -> JSONValue? {
        let previous = stamp(stored)
        if let incoming = stamp(proposed) {
            if let previous, incoming.time < previous.time || (incoming.time == previous.time && incoming.writer <= previous.writer) { return nil }
            return proposed
        }
        // Reset (nil) and legacy/manual orders are host-authored writes, stamped before broadcast.
        guard let order = proposed ?? SettingsSchema.descriptor(for: path)?.defaultValue,
              case .array(let values) = order else { return nil }
        let time = max(now, (previous?.time ?? 0) + 1)
        return .array([.string("\(prefix)\(time)/\(writer)")] + values)
    }
}

extension CmuxConfigFile {
    /// No suspension between the read, comparison and write: this is one serialized transaction.
    func setInspectorOrder(_ proposed: JSONValue?) throws {
        let stored = try value(at: InspectorOrderRevision.path)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let next = InspectorOrderRevision.resolving(proposed, over: stored, now: now, writer: UUID().uuidString) else { return }
        try set(next, at: InspectorOrderRevision.path)
    }
}
