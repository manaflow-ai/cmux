import Foundation

/// A validated targeted notice for one native inventory lease.
///
/// These notices arrive through ``DaemonSideEvents`` independently of the tree
/// snapshot. Match the captured connection generation, owner and watch ID before
/// acting; a valid notice does not establish current route admission.
public nonisolated enum AgentInventoryWatchEvent: Sendable, Hashable {
    /// The owner's cache advanced; re-read only through the existing admitted reader.
    case changed(AgentInventoryWatchReceipt)
    /// The named lease ended; an old notice must not retire a newer lease.
    case ended(machine: ResourceID, watchID: String, reason: String)

    /// Reads a normalized inventory notice from the side-event channel.
    /// - Parameter event: An event already decoded from this native control connection.
    /// - Returns: Nil for unrelated or malformed events; no alternate owner is inferred.
    public init?(_ event: DaemonEvent) {
        guard case .unknown(let name, let payload) = event,
              let owner = payload["machine"]?.stringValue,
              let watch = payload["watch_id"]?.stringValue else { return nil }
        let machine = ResourceID(rawValue: owner)
        if name == "agent-inventory-changed" {
            guard let decimal = payload["revision"]?.stringValue, let revision = UInt64(decimal),
                  let receipt = AgentInventoryWatchReceipt(machine: machine, watchID: watch, revision: revision) else { return nil }
            self = .changed(receipt)
        } else if name == "agent-inventory-watch-ended", let reason = payload["reason"]?.stringValue,
                  let ended = Self.endedNotice(machine: machine, watchID: watch, reason: reason) {
            self = ended
        } else { return nil }
    }

    /// Decodes before generic JSON's Double representation can round UInt64.
    static func decode(name: String, line: Data, decoder: WireDecoder = WireCoding.decoder()) -> Self? {
        if name == "agent-inventory-changed", let receipt = try? decoder.decode(AgentInventoryWatchReceipt.self, from: line) {
            return .changed(receipt)
        }
        guard name == "agent-inventory-watch-ended", let end = try? decoder.decode(Ended.self, from: line) else { return nil }
        return endedNotice(machine: end.machine, watchID: end.watchID, reason: end.reason)
    }

    /// Keep the side-event ABI, with the exact revision retained as decimal text.
    var payload: JSONValue {
        switch self {
        case .changed(let receipt):
            .object(["event": .string("agent-inventory-changed"), "machine": .string(receipt.machine.rawValue),
                     "watch_id": .string(receipt.watchID), "revision": .string(String(receipt.revision))])
        case .ended(let machine, let watchID, let reason):
            .object(["event": .string("agent-inventory-watch-ended"), "machine": .string(machine.rawValue),
                     "watch_id": .string(watchID), "reason": .string(reason)])
        }
    }

    private static func endedNotice(machine: ResourceID, watchID: String, reason: String) -> Self? {
        guard MachineCatalogRecord.validID(machine), AgentInventoryWatchReceipt.validWatchID(watchID),
              reason.hasPrefix("agent_inventory."), (17...64).contains(reason.utf8.count),
              reason.utf8.allSatisfy({ (97...122).contains($0) || $0 == 46 || $0 == 95 }) else { return nil }
        return .ended(machine: machine, watchID: watchID, reason: reason)
    }

    private struct Ended: Decodable {
        let machine: ResourceID
        let watchID: String
        let reason: String
        enum CodingKeys: String, CodingKey {
            case machine, reason
            case watchID = "watch_id"
        }
    }
}
