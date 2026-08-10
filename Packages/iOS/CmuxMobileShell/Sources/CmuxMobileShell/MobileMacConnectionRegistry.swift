import Foundation
import Observation

/// One authoritative entry per connected Mac.
///
/// A focused entry owns the terminal render subscription. A control entry owns
/// only aggregate-state subscriptions and command RPCs. Replacing an entry's
/// role never requires replacing its underlying RPC client.
@MainActor
@Observable
final class MobileMacConnectionRegistry {
    private var entriesByOwnerKey: [MacPairingKey: Entry] = [:] {
        didSet { rebuildSnapshots() }
    }

    private(set) var snapshots: [MobileMacConnectionSnapshot] = []

    var controlSubscriptions: ControlSubscriptions {
        ControlSubscriptions(registry: self)
    }

    var focusedConnections: FocusedConnections {
        FocusedConnections(registry: self)
    }

    var controlEntries: [ControlSubscriptions.Element] {
        entriesByOwnerKey.compactMap { ownerKey, entry in
            guard case .control(let subscription) = entry else { return nil }
            return (key: ownerKey, value: subscription)
        }
    }

    var controlEntryCount: Int {
        entriesByOwnerKey.values.reduce(into: 0) { count, entry in
            if case .control = entry {
                count += 1
            }
        }
    }

    func controlSubscription(
        for ownerKey: MacPairingKey
    ) -> SecondaryMacSubscription? {
        guard case .control(let subscription) = entriesByOwnerKey[ownerKey] else {
            return nil
        }
        return subscription
    }

    func setControlSubscription(
        _ subscription: SecondaryMacSubscription?,
        for ownerKey: MacPairingKey
    ) {
        if let subscription {
            // Compatibility setters may refresh their own role, but cannot
            // silently destroy the opposite owner. Cross-role changes use the
            // explicit transition methods below.
            if case .focused = entriesByOwnerKey[ownerKey] {
                return
            }
            entriesByOwnerKey[ownerKey] = .control(subscription)
        } else if case .control = entriesByOwnerKey[ownerKey] {
            entriesByOwnerKey[ownerKey] = nil
        }
    }

    /// Publish a newly established control owner only while the pool still has
    /// capacity. The count check and insertion share one MainActor operation,
    /// so concurrent dial completions cannot each consume the last slot.
    func insertControlIfAbsent(
        _ subscription: SecondaryMacSubscription,
        maximumControlCount: Int
    ) -> Bool {
        guard entriesByOwnerKey[subscription.ownerKey] == nil,
              controlEntryCount < maximumControlCount else {
            return false
        }
        entriesByOwnerKey[subscription.ownerKey] = .control(subscription)
        return true
    }

    func focusedConnection(for ownerKey: MacPairingKey) -> MacConnection? {
        guard case .focused(let connection) = entriesByOwnerKey[ownerKey] else {
            return nil
        }
        return connection
    }

    /// The focused connection on the given physical device, regardless of
    /// instance tag. Safe as a device-level read because the registry holds at
    /// most one focused entry; writes must always name the exact pairing.
    func focusedConnection(onDevice macDeviceID: String) -> MacConnection? {
        for (ownerKey, entry) in entriesByOwnerKey {
            if case .focused(let connection) = entry,
               ownerKey.isOnDevice(macDeviceID) {
                return connection
            }
        }
        return nil
    }

    func setFocusedConnection(
        _ connection: MacConnection?,
        for ownerKey: MacPairingKey
    ) {
        if let connection {
            if case .control = entriesByOwnerKey[ownerKey] {
                return
            }
            entriesByOwnerKey[ownerKey] = .focused(connection)
        } else if case .focused = entriesByOwnerKey[ownerKey] {
            entriesByOwnerKey[ownerKey] = nil
        }
    }

    /// Atomically publish focus and return any control owner it displaced.
    /// Callers synchronously retire that owner before yielding again.
    func transitionToFocused(
        _ connection: MacConnection
    ) -> SecondaryMacSubscription? {
        let displaced: SecondaryMacSubscription?
        if case .control(let subscription) = entriesByOwnerKey[connection.ownerKey] {
            displaced = subscription
        } else {
            displaced = nil
        }
        entriesByOwnerKey[connection.ownerKey] = .focused(connection)
        return displaced
    }

    /// Atomically demote the expected focused owner to control. A different
    /// focused client means another handoff won and this transition is refused.
    func transitionToControl(
        _ subscription: SecondaryMacSubscription,
        replacing connection: MacConnection,
        maximumControlCount: Int
    ) -> Bool {
        guard case .focused(let current) =
                entriesByOwnerKey[connection.ownerKey],
              current.client === connection.client,
              current.generation == connection.generation,
              controlEntryCount < maximumControlCount else {
            return false
        }
        entriesByOwnerKey[connection.ownerKey] = .control(subscription)
        return true
    }

    /// Vacate the control slot being promoted and demote the prepared focus in
    /// one registry publication. The control count is unchanged, so a full
    /// pool can switch focus without exposing two focused owners or exceeding
    /// its resource cap.
    func exchangePromotedControlForDemotedFocus(
        promotedControl: SecondaryMacSubscription,
        demotedControl: SecondaryMacSubscription,
        replacing focusedConnection: MacConnection
    ) -> Bool {
        guard promotedControl.ownerKey
                != focusedConnection.ownerKey,
              case .control(let currentPromoted) =
                entriesByOwnerKey[promotedControl.ownerKey],
              currentPromoted === promotedControl,
              case .focused(let currentFocused) =
                entriesByOwnerKey[focusedConnection.ownerKey],
              currentFocused.client === focusedConnection.client,
              currentFocused.generation
                == focusedConnection.generation else {
            return false
        }
        var updated = entriesByOwnerKey
        updated[promotedControl.ownerKey] = nil
        updated[focusedConnection.ownerKey] =
            .control(demotedControl)
        entriesByOwnerKey = updated
        return true
    }

    /// Remove only the focused owner that the caller actually prepared.
    /// A newer focus generation, including one reusing the same client, is left
    /// untouched.
    @discardableResult
    func removeFocused(ifMatching connection: MacConnection) -> Bool {
        guard case .focused(let current) = entriesByOwnerKey[connection.ownerKey],
              current.client === connection.client,
              current.generation == connection.generation else {
            return false
        }
        entriesByOwnerKey[connection.ownerKey] = nil
        return true
    }

    func isFocused(ifMatching connection: MacConnection) -> Bool {
        guard case .focused(let current) =
                entriesByOwnerKey[connection.ownerKey] else {
            return false
        }
        return current.client === connection.client
            && current.generation == connection.generation
    }

    func ownsClient(of connection: MacConnection) -> Bool {
        switch entriesByOwnerKey[connection.ownerKey] {
        case .focused(let current):
            return current.client === connection.client
        case .control(let current):
            return current.client === connection.client
        case nil:
            return false
        }
    }

    func removeAllControlSubscriptions() {
        let controlKeys = entriesByOwnerKey.compactMap { ownerKey, entry -> MacPairingKey? in
            if case .control = entry { return ownerKey }
            return nil
        }
        for ownerKey in controlKeys {
            entriesByOwnerKey[ownerKey] = nil
        }
    }

    func removeAllFocusedConnections() {
        let focusedKeys = entriesByOwnerKey.compactMap { ownerKey, entry -> MacPairingKey? in
            if case .focused = entry { return ownerKey }
            return nil
        }
        for ownerKey in focusedKeys {
            entriesByOwnerKey[ownerKey] = nil
        }
    }

    func removeAll() {
        entriesByOwnerKey.removeAll()
    }

    private func rebuildSnapshots() {
        snapshots = entriesByOwnerKey.map { ownerKey, entry in
            switch entry {
            case .control(let subscription):
                return MobileMacConnectionSnapshot(
                    macDeviceID: ownerKey.canonicalMacDeviceID,
                    displayName: mobileMacConnectionDisplayName(
                        subscription.displayName,
                        fallback: ownerKey.canonicalMacDeviceID
                    ),
                    instanceTag: subscription.authenticatedInstanceTag
                        ?? subscription.storedInstanceTag,
                    role: .control
                )
            case .focused(let connection):
                return MobileMacConnectionSnapshot(
                    macDeviceID: ownerKey.canonicalMacDeviceID,
                    displayName: mobileMacConnectionDisplayName(
                        connection.displayName,
                        fallback: ownerKey.canonicalMacDeviceID
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

}

private func mobileMacConnectionDisplayName(
    _ value: String?,
    fallback: String
) -> String {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return fallback
    }
    return value
}
