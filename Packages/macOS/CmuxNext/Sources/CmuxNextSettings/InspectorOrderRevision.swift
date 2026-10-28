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
        return authoring(proposed, over: stored, now: now, writer: writer)
    }

    /// External file edits are authoritative even when they retain or remove the old marker.
    static func authoring(_ proposed: JSONValue?, over stored: JSONValue?, now: Int64, writer: String) -> JSONValue? {
        guard let order = proposed ?? SettingsSchema.descriptor(for: path)?.defaultValue,
              case .array(let values) = order else { return nil }
        let time = max(now, max((stamp(stored)?.time ?? 0) + 1, (stamp(proposed)?.time ?? 0) + 1))
        let sections = values.first?.stringValue?.hasPrefix(prefix) == true ? Array(values.dropFirst()) : values
        return .array([.string("\(prefix)\(time)/\(writer)")] + sections)
    }
}

extension CmuxConfigFile {
    /// No suspension between the read, comparison and write: this is one serialized transaction.
    func setInspectorOrder(_ proposed: JSONValue?, published: JSONValue? = nil) throws {
        _ = try sourceReconcilingInspectorOrder(previous: published)
        let stored = inspectorOrderPublished
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let next = InspectorOrderRevision.resolving(proposed, over: stored, now: now, writer: UUID().uuidString) else { return }
        try set(next, at: InspectorOrderRevision.path)
        inspectorOrderPublished = next
    }

    /// The watcher and RPC writer share this serialized reconciliation. Rewriting a stamp causes
    /// one more file event, which is a no-op because the published value is recorded here.
    func sourceReconcilingInspectorOrder(previous: JSONValue?) throws -> String {
        let source = try source()
        guard let root = try? JSONC.parse(source), case .object = root else { return source }
        let path = InspectorOrderRevision.path
        let current = root.value(at: path)
        if !inspectorOrderObserved {
            if let previous { inspectorOrderPublished = previous.value(at: path) }
            else { inspectorOrderPublished = current }
            inspectorOrderObserved = true
        }
        guard current != inspectorOrderPublished,
              managedGuard.managedKeys[path.joined(separator: ".")] == nil else { return source }
        if let current, SettingsSchema.descriptor(for: path)?.accepts(current) != true { return source }
        if let incoming = InspectorOrderRevision.stamp(current),
           let published = InspectorOrderRevision.stamp(inspectorOrderPublished) {
            let isOlder = incoming.time < published.time
                || (incoming.time == published.time && incoming.writer < published.writer)
            if isOlder {
                // A delayed RPC or another pane's stale publish must not replace the
                // version already held by this actor. Restore the held value instead.
                try set(inspectorOrderPublished!, at: path)
                return try self.source()
            }
            let isNewer = incoming.time > published.time
                || (incoming.time == published.time && incoming.writer > published.writer)
            if isNewer {
                // A different pane already published a newer version. Accept it as
                // the host's source of truth without restamping (which would make
                // two watchers continually rewrite one another).
                inspectorOrderPublished = current
                return source
            }
            // Equal stamp with changed sections is an external file edit; fall
            // through and assign it a fresh stamp below.
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let next = InspectorOrderRevision.authoring(current, over: inspectorOrderPublished, now: now, writer: UUID().uuidString) else { return source }
        try set(next, at: path)
        inspectorOrderPublished = next
        return try self.source()
    }
}
