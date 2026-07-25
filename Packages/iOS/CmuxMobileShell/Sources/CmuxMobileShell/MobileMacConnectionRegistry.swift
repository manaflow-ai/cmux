import Foundation
import Observation

/// The work a live Mac connection currently performs for the iOS app.
public enum MobileMacConnectionRole: Equatable, Sendable {
    /// Carries aggregate workspace, presence-adjacent state, notification, and command traffic.
    case control
    /// Carries control traffic plus the focused terminal's render stream.
    case focused
}

/// Read-only status for one live connection in the iOS per-Mac pool.
public struct MobileMacConnectionSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { macDeviceID }

    public let macDeviceID: String
    public let displayName: String
    public let instanceTag: String?
    public let role: MobileMacConnectionRole

    public init(
        macDeviceID: String,
        displayName: String,
        instanceTag: String?,
        role: MobileMacConnectionRole
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.instanceTag = instanceTag
        self.role = role
    }
}

/// One authoritative entry per connected Mac.
///
/// A focused entry owns the terminal render subscription. A control entry owns
/// only aggregate-state subscriptions and command RPCs. Replacing an entry's
/// role never requires replacing its underlying RPC client.
@MainActor
@Observable
final class MobileMacConnectionRegistry {
    private enum Entry {
        case control(SecondaryMacSubscription)
        case focused(MacConnection)
    }

    private var entriesByMacDeviceID: [String: Entry] = [:] {
        didSet { rebuildSnapshots() }
    }

    private(set) var snapshots: [MobileMacConnectionSnapshot] = []

    var controlSubscriptions: [String: SecondaryMacSubscription] {
        get {
            entriesByMacDeviceID.compactMapValues { entry in
                guard case .control(let subscription) = entry else { return nil }
                return subscription
            }
        }
        set {
            entriesByMacDeviceID = entriesByMacDeviceID.filter {
                if case .focused = $0.value { return true }
                return false
            }
            for (macDeviceID, subscription) in newValue {
                entriesByMacDeviceID[macDeviceID] = .control(subscription)
            }
        }
    }

    var focusedConnections: [String: MacConnection] {
        get {
            entriesByMacDeviceID.compactMapValues { entry in
                guard case .focused(let connection) = entry else { return nil }
                return connection
            }
        }
        set {
            entriesByMacDeviceID = entriesByMacDeviceID.filter {
                if case .control = $0.value { return true }
                return false
            }
            for (macDeviceID, connection) in newValue {
                entriesByMacDeviceID[macDeviceID] = .focused(connection)
            }
        }
    }

    func removeAll() {
        entriesByMacDeviceID.removeAll()
    }

    private func rebuildSnapshots() {
        snapshots = entriesByMacDeviceID.map { macDeviceID, entry in
            switch entry {
            case .control(let subscription):
                return MobileMacConnectionSnapshot(
                    macDeviceID: macDeviceID,
                    displayName: Self.displayName(
                        subscription.displayName,
                        fallback: macDeviceID
                    ),
                    instanceTag: subscription.authenticatedInstanceTag
                        ?? subscription.storedInstanceTag,
                    role: .control
                )
            case .focused(let connection):
                return MobileMacConnectionSnapshot(
                    macDeviceID: macDeviceID,
                    displayName: Self.displayName(
                        connection.displayName,
                        fallback: macDeviceID
                    ),
                    instanceTag: connection.instanceTag,
                    role: .focused
                )
            }
        }
        .sorted {
            if $0.role != $1.role { return $0.role == .focused }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private static func displayName(_ value: String?, fallback: String) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return fallback
        }
        return value
    }
}
