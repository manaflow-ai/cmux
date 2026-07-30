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
    private var entriesByMacDeviceID: [String: Entry] = [:] {
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
        entriesByMacDeviceID.compactMap { macDeviceID, entry in
            guard case .control(let subscription) = entry else { return nil }
            return (key: macDeviceID, value: subscription)
        }
    }

    var controlEntryCount: Int {
        entriesByMacDeviceID.values.reduce(into: 0) { count, entry in
            if case .control = entry {
                count += 1
            }
        }
    }

    func controlSubscription(
        for macDeviceID: String
    ) -> SecondaryMacSubscription? {
        guard case .control(let subscription) = entriesByMacDeviceID[macDeviceID] else {
            return nil
        }
        return subscription
    }

    func setControlSubscription(
        _ subscription: SecondaryMacSubscription?,
        for macDeviceID: String
    ) {
        if let subscription {
            // Compatibility setters may refresh their own role, but cannot
            // silently destroy the opposite owner. Cross-role changes use the
            // explicit transition methods below.
            if case .focused = entriesByMacDeviceID[macDeviceID] {
                return
            }
            entriesByMacDeviceID[macDeviceID] = .control(subscription)
        } else if case .control = entriesByMacDeviceID[macDeviceID] {
            entriesByMacDeviceID[macDeviceID] = nil
        }
    }

    /// Publish a newly established control owner only while the pool still has
    /// capacity. The count check and insertion share one MainActor operation,
    /// so concurrent dial completions cannot each consume the last slot.
    func insertControlIfAbsent(
        _ subscription: SecondaryMacSubscription,
        maximumControlCount: Int
    ) -> Bool {
        guard entriesByMacDeviceID[subscription.macDeviceID] == nil,
              controlEntryCount < maximumControlCount else {
            return false
        }
        entriesByMacDeviceID[subscription.macDeviceID] = .control(subscription)
        return true
    }

    func focusedConnection(for macDeviceID: String) -> MacConnection? {
        guard case .focused(let connection) = entriesByMacDeviceID[macDeviceID] else {
            return nil
        }
        return connection
    }

    func setFocusedConnection(
        _ connection: MacConnection?,
        for macDeviceID: String
    ) {
        if let connection {
            if case .control = entriesByMacDeviceID[macDeviceID] {
                return
            }
            entriesByMacDeviceID[macDeviceID] = .focused(connection)
        } else if case .focused = entriesByMacDeviceID[macDeviceID] {
            entriesByMacDeviceID[macDeviceID] = nil
        }
    }

    /// Atomically publish focus and return any control owner it displaced.
    /// Callers synchronously retire that owner before yielding again.
    func transitionToFocused(
        _ connection: MacConnection
    ) -> SecondaryMacSubscription? {
        let displaced: SecondaryMacSubscription?
        if case .control(let subscription) = entriesByMacDeviceID[connection.macDeviceID] {
            displaced = subscription
        } else {
            displaced = nil
        }
        entriesByMacDeviceID[connection.macDeviceID] = .focused(connection)
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
                entriesByMacDeviceID[connection.macDeviceID],
              current.client === connection.client,
              current.generation == connection.generation,
              controlEntryCount < maximumControlCount else {
            return false
        }
        entriesByMacDeviceID[connection.macDeviceID] = .control(subscription)
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
        guard promotedControl.macDeviceID
                != focusedConnection.macDeviceID,
              case .control(let currentPromoted) =
                entriesByMacDeviceID[promotedControl.macDeviceID],
              currentPromoted === promotedControl,
              case .focused(let currentFocused) =
                entriesByMacDeviceID[focusedConnection.macDeviceID],
              currentFocused.client === focusedConnection.client,
              currentFocused.generation
                == focusedConnection.generation else {
            return false
        }
        var updated = entriesByMacDeviceID
        updated[promotedControl.macDeviceID] = nil
        updated[focusedConnection.macDeviceID] =
            .control(demotedControl)
        entriesByMacDeviceID = updated
        return true
    }

    /// Remove only the focused owner that the caller actually prepared.
    /// A newer focus generation, including one reusing the same client, is left
    /// untouched.
    @discardableResult
    func removeFocused(ifMatching connection: MacConnection) -> Bool {
        guard case .focused(let current) = entriesByMacDeviceID[connection.macDeviceID],
              current.client === connection.client,
              current.generation == connection.generation else {
            return false
        }
        entriesByMacDeviceID[connection.macDeviceID] = nil
        return true
    }

    func isFocused(ifMatching connection: MacConnection) -> Bool {
        guard case .focused(let current) =
                entriesByMacDeviceID[connection.macDeviceID] else {
            return false
        }
        return current.client === connection.client
            && current.generation == connection.generation
    }

    func ownsClient(of connection: MacConnection) -> Bool {
        switch entriesByMacDeviceID[connection.macDeviceID] {
        case .focused(let current):
            return current.client === connection.client
        case .control(let current):
            return current.client === connection.client
        case nil:
            return false
        }
    }

    func removeAllControlSubscriptions() {
        let controlIDs = entriesByMacDeviceID.compactMap { macDeviceID, entry in
            if case .control = entry { return macDeviceID }
            return nil
        }
        for macDeviceID in controlIDs {
            entriesByMacDeviceID[macDeviceID] = nil
        }
    }

    func removeAllFocusedConnections() {
        let focusedIDs = entriesByMacDeviceID.compactMap { macDeviceID, entry in
            if case .focused = entry { return macDeviceID }
            return nil
        }
        for macDeviceID in focusedIDs {
            entriesByMacDeviceID[macDeviceID] = nil
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
                    displayName: mobileMacConnectionDisplayName(
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
                    displayName: mobileMacConnectionDisplayName(
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
