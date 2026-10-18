import Foundation

/// What one sync of one machine will do.
///
/// ``toSend`` holds values and must stay in process: hand it to the env delivery and
/// drop it. Every textual rendering of a plan is names only.
public struct CloudSecretPlan: Sendable, Equatable {
    public let machineID: String
    /// The full effective set, sorted by name, when anything changed (the receiver merges);
    /// empty when the machine is current.
    public let toSend: [CloudEnvDelivery.Entry]
    /// Names delivered earlier that no longer apply, sorted.
    public let toRemove: [String]
    /// Every effective name to its winning scope.
    public let effective: [String: CloudSecretScope]
    /// Every effective name to its fingerprint; what the ledger records on success.
    public let fingerprints: [String: String]

    public init(
        machineID: String,
        toSend: [CloudEnvDelivery.Entry],
        toRemove: [String],
        effective: [String: CloudSecretScope],
        fingerprints: [String: String]
    ) {
        self.machineID = machineID
        self.toSend = toSend
        self.toRemove = toRemove
        self.effective = effective
        self.fingerprints = fingerprints
    }

    /// True when the machine already has exactly the effective set.
    public var isNoop: Bool { toSend.isEmpty && toRemove.isEmpty }

    /// Names in ``toSend``.
    public var sendNames: [String] { toSend.map(\.key) }
}

extension CloudSecretPlan: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "CloudSecretPlan(machineID: \(machineID), send: \(sendNames), remove: \(toRemove))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "machineID": machineID,
                "toSend": sendNames,
                "toRemove": toRemove,
                "effective": effective,
                "fingerprints": fingerprints
            ],
            displayStyle: .struct
        )
    }
}
