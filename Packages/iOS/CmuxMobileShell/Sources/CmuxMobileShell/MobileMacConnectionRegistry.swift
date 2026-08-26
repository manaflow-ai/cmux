import Foundation
import Observation

/// One authoritative session entry per connected Mac.
///
/// Control and focused work are independent capabilities on the same RPC
/// client. A focus handoff can therefore add terminal work without replacing
/// the peer connection or stopping its aggregate-state subscription.
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
            guard let subscription = entry.controlSubscription else {
                return nil
            }
            return (key: ownerKey, value: subscription)
        }
    }

    var controlEntryCount: Int {
        entriesByOwnerKey.values.reduce(into: 0) { count, entry in
            if entry.controlSubscription != nil { count += 1 }
        }
    }

    var sessionCount: Int {
        entriesByOwnerKey.count
    }

    func controlSubscription(
        for ownerKey: MacPairingKey
    ) -> SecondaryMacSubscription? {
        entriesByOwnerKey[ownerKey]?.controlSubscription
    }

    func setControlSubscription(
        _ subscription: SecondaryMacSubscription?,
        for ownerKey: MacPairingKey
    ) {
        if let subscription {
            var entry = entriesByOwnerKey[ownerKey] ?? Entry()
            guard entry.focusedConnection == nil
                    || entry.focusedConnection?.client === subscription.client else {
                return
            }
            entry.controlSubscription = subscription
            entriesByOwnerKey[ownerKey] = entry
            return
        }
        guard var entry = entriesByOwnerKey[ownerKey],
              entry.controlSubscription != nil else {
            return
        }
        entry.controlSubscription = nil
        entriesByOwnerKey[ownerKey] = entry.isEmpty ? nil : entry
    }

    /// Remove one exact control capability without touching a focused
    /// capability that may share the same peer entry.
    @discardableResult
    func removeControlSubscription(
        ifMatching subscription: SecondaryMacSubscription
    ) -> Bool {
        let ownerKey = subscription.ownerKey
        guard var entry = entriesByOwnerKey[ownerKey],
              entry.controlSubscription === subscription else {
            return false
        }
        entry.controlSubscription = nil
        entriesByOwnerKey[ownerKey] = entry.isEmpty ? nil : entry
        return true
    }

    /// Publish a newly established control owner only while the pool still has
    /// capacity. The count check and insertion share one MainActor operation,
    /// so concurrent dial completions cannot each consume the last slot.
    func insertControlIfAbsent(
        _ subscription: SecondaryMacSubscription,
        maximumControlCount: Int
    ) -> Bool {
        let focusedSessionAllowance = entriesByOwnerKey.values.contains {
            $0.focusedConnection != nil
        } ? 1 : 0
        guard entriesByOwnerKey[subscription.ownerKey] == nil,
              sessionCount
                < maximumControlCount + focusedSessionAllowance else {
            return false
        }
        entriesByOwnerKey[subscription.ownerKey] = Entry(
            controlSubscription: subscription
        )
        return true
    }

    func focusedConnection(for ownerKey: MacPairingKey) -> MacConnection? {
        entriesByOwnerKey[ownerKey]?.focusedConnection
    }

    /// The focused connection on the given physical device, regardless of
    /// instance tag. Safe as a device-level read because the registry holds at
    /// most one focused entry; writes must always name the exact pairing.
    func focusedConnection(onDevice macDeviceID: String) -> MacConnection? {
        for (ownerKey, entry) in entriesByOwnerKey
        where ownerKey.isOnDevice(macDeviceID) {
            if let connection = entry.focusedConnection { return connection }
        }
        return nil
    }

    func setFocusedConnection(
        _ connection: MacConnection?,
        for ownerKey: MacPairingKey
    ) {
        if let connection {
            var entry = entriesByOwnerKey[ownerKey] ?? Entry()
            guard entry.controlSubscription == nil
                    || entry.controlSubscription?.client === connection.client else {
                return
            }
            entry.focusedConnection = connection
            entriesByOwnerKey[ownerKey] = entry
            return
        }
        guard var entry = entriesByOwnerKey[ownerKey],
              entry.focusedConnection != nil else {
            return
        }
        entry.focusedConnection = nil
        entriesByOwnerKey[ownerKey] = entry.isEmpty ? nil : entry
    }

    /// Publish focus with the legacy exclusive-role behavior and return the
    /// control owner it displaced.
    func transitionToFocused(
        _ connection: MacConnection
    ) -> SecondaryMacSubscription? {
        var entry = entriesByOwnerKey[connection.ownerKey] ?? Entry()
        let displaced = entry.controlSubscription
        entry.controlSubscription = nil
        entry.focusedConnection = connection
        entriesByOwnerKey[connection.ownerKey] = entry
        return displaced
    }

    /// Move the single focus lease while preserving every same-client control
    /// subscription. Existing peer connections stay admitted throughout the
    /// handoff.
    func transitionToFocusedPreservingControl(
        _ connection: MacConnection
    ) -> Bool {
        var target = entriesByOwnerKey[connection.ownerKey] ?? Entry()
        guard target.controlSubscription == nil
                || target.controlSubscription?.client === connection.client else {
            return false
        }

        var updated = entriesByOwnerKey
        let previousFocusKeys = updated.compactMap { ownerKey, entry in
            ownerKey != connection.ownerKey && entry.focusedConnection != nil
                ? ownerKey
                : nil
        }
        for ownerKey in previousFocusKeys {
            guard var entry = updated[ownerKey] else { continue }
            entry.focusedConnection = nil
            updated[ownerKey] = entry.isEmpty ? nil : entry
        }
        target.focusedConnection = connection
        updated[connection.ownerKey] = target
        entriesByOwnerKey = updated
        return true
    }

    /// Add control work to the same client while it still owns focus. This does
    /// not consume another peer slot because the transport session is unchanged.
    func installControlAlongsideFocus(
        _ subscription: SecondaryMacSubscription,
        replacing connection: MacConnection
    ) -> Bool {
        guard var entry = entriesByOwnerKey[connection.ownerKey],
              let current = entry.focusedConnection,
              current.client === connection.client,
              current.generation == connection.generation,
              subscription.client === connection.client else {
            return false
        }
        entry.controlSubscription = subscription
        entriesByOwnerKey[connection.ownerKey] = entry
        return true
    }

    /// Atomically demote the expected focused owner to control. A different
    /// focused client means another handoff won and this transition is refused.
    func transitionToControl(
        _ subscription: SecondaryMacSubscription,
        replacing connection: MacConnection,
        maximumControlCount: Int
    ) -> Bool {
        guard var entry = entriesByOwnerKey[connection.ownerKey],
              let current = entry.focusedConnection,
              current.client === connection.client,
              current.generation == connection.generation else {
            return false
        }
        if let existingControl = entry.controlSubscription {
            guard existingControl.client === connection.client else { return false }
        } else {
            guard controlEntryCount < maximumControlCount else { return false }
            entry.controlSubscription = subscription
        }
        entry.focusedConnection = nil
        entriesByOwnerKey[connection.ownerKey] = entry
        return true
    }

    /// Vacate the control slot being promoted and demote the prepared focus in
    /// one registry publication. This retains the legacy teardown-based path for
    /// transports that cannot multiplex peer lanes.
    func exchangePromotedControlForDemotedFocus(
        promotedControl: SecondaryMacSubscription,
        demotedControl: SecondaryMacSubscription,
        replacing focusedConnection: MacConnection
    ) -> Bool {
        guard promotedControl.ownerKey != focusedConnection.ownerKey,
              var promotedEntry = entriesByOwnerKey[promotedControl.ownerKey],
              promotedEntry.controlSubscription === promotedControl,
              var focusedEntry = entriesByOwnerKey[focusedConnection.ownerKey],
              let currentFocused = focusedEntry.focusedConnection,
              currentFocused.client === focusedConnection.client,
              currentFocused.generation == focusedConnection.generation else {
            return false
        }
        promotedEntry.controlSubscription = nil
        focusedEntry.focusedConnection = nil
        if let existingControl = focusedEntry.controlSubscription {
            guard existingControl.client === focusedConnection.client else {
                return false
            }
        } else {
            focusedEntry.controlSubscription = demotedControl
        }
        var updated = entriesByOwnerKey
        updated[promotedControl.ownerKey] = promotedEntry.isEmpty
            ? nil
            : promotedEntry
        updated[focusedConnection.ownerKey] = focusedEntry
        entriesByOwnerKey = updated
        return true
    }

    /// Remove only the focused owner that the caller actually prepared. A newer
    /// focus generation, including one reusing the same client, is untouched.
    @discardableResult
    func removeFocused(ifMatching connection: MacConnection) -> Bool {
        guard var entry = entriesByOwnerKey[connection.ownerKey],
              let current = entry.focusedConnection,
              current.client === connection.client,
              current.generation == connection.generation else {
            return false
        }
        entry.focusedConnection = nil
        entriesByOwnerKey[connection.ownerKey] = entry.isEmpty ? nil : entry
        return true
    }

    func isFocused(ifMatching connection: MacConnection) -> Bool {
        guard let current = entriesByOwnerKey[connection.ownerKey]?
                .focusedConnection else {
            return false
        }
        return current.client === connection.client
            && current.generation == connection.generation
    }

    func ownsClient(of connection: MacConnection) -> Bool {
        guard let entry = entriesByOwnerKey[connection.ownerKey] else {
            return false
        }
        return entry.focusedConnection?.client === connection.client
            || entry.controlSubscription?.client === connection.client
    }

    func removeAllControlSubscriptions() {
        var updated = entriesByOwnerKey
        for (ownerKey, entry) in updated where entry.controlSubscription != nil {
            var entry = entry
            entry.controlSubscription = nil
            updated[ownerKey] = entry.isEmpty ? nil : entry
        }
        entriesByOwnerKey = updated
    }

    func removeAllFocusedConnections() {
        var updated = entriesByOwnerKey
        for (ownerKey, entry) in updated where entry.focusedConnection != nil {
            var entry = entry
            entry.focusedConnection = nil
            updated[ownerKey] = entry.isEmpty ? nil : entry
        }
        entriesByOwnerKey = updated
    }

    func removeAll() {
        entriesByOwnerKey.removeAll()
    }

    private func rebuildSnapshots() {
        snapshots = entriesByOwnerKey.compactMap { ownerKey, entry in
            if let connection = entry.focusedConnection {
                return MobileMacConnectionSnapshot(
                    macDeviceID: ownerKey.canonicalMacDeviceID,
                    displayName: Self.displayName(
                        connection.displayName,
                        fallback: ownerKey.canonicalMacDeviceID
                    ),
                    instanceTag: connection.instanceTag,
                    role: .focused
                )
            }
            guard let subscription = entry.controlSubscription else {
                return nil
            }
            return MobileMacConnectionSnapshot(
                macDeviceID: ownerKey.canonicalMacDeviceID,
                displayName: Self.displayName(
                    subscription.displayName,
                    fallback: ownerKey.canonicalMacDeviceID
                ),
                instanceTag: subscription.authenticatedInstanceTag
                    ?? subscription.storedInstanceTag,
                role: .control
            )
        }
        .sorted {
            if $0.role != $1.role { return $0.role == .focused }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private static func displayName(
        _ value: String?,
        fallback: String
    ) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return fallback
        }
        return value
    }
}
