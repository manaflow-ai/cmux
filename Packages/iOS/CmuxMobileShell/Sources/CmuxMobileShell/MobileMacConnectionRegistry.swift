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

    /// Dictionary-like compatibility view whose keyed reads and writes stay
    /// O(1). Enumeration intentionally snapshots only the control entries once.
    @MainActor
    struct ControlSubscriptions: @MainActor Sequence {
        typealias Element = (key: String, value: SecondaryMacSubscription)

        unowned let registry: MobileMacConnectionRegistry

        subscript(macDeviceID: String) -> SecondaryMacSubscription? {
            get { registry.controlSubscription(for: macDeviceID) }
            nonmutating set {
                registry.setControlSubscription(newValue, for: macDeviceID)
            }
        }

        var keys: [String] {
            registry.controlEntries.map(\.key)
        }

        var count: Int {
            registry.controlEntryCount
        }

        var isEmpty: Bool {
            count == 0
        }

        func makeIterator() -> Array<Element>.Iterator {
            registry.controlEntries.makeIterator()
        }

        func removeAll() {
            registry.removeAllControlSubscriptions()
        }
    }

    /// Dictionary-like compatibility view whose keyed reads and writes stay
    /// O(1). The app owns at most one focused entry, so no enumeration API is
    /// needed.
    @MainActor
    struct FocusedConnections {
        unowned let registry: MobileMacConnectionRegistry

        subscript(macDeviceID: String) -> MacConnection? {
            get { registry.focusedConnection(for: macDeviceID) }
            nonmutating set {
                registry.setFocusedConnection(newValue, for: macDeviceID)
            }
        }

        func removeAll() {
            registry.removeAllFocusedConnections()
        }
    }

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

    private var controlEntries: [ControlSubscriptions.Element] {
        entriesByMacDeviceID.compactMap { macDeviceID, entry in
            guard case .control(let subscription) = entry else { return nil }
            return (key: macDeviceID, value: subscription)
        }
    }

    private var controlEntryCount: Int {
        entriesByMacDeviceID.values.reduce(into: 0) { count, entry in
            if case .control = entry {
                count += 1
            }
        }
    }

    private func controlSubscription(
        for macDeviceID: String
    ) -> SecondaryMacSubscription? {
        guard case .control(let subscription) = entriesByMacDeviceID[macDeviceID] else {
            return nil
        }
        return subscription
    }

    private func setControlSubscription(
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

    private func focusedConnection(for macDeviceID: String) -> MacConnection? {
        guard case .focused(let connection) = entriesByMacDeviceID[macDeviceID] else {
            return nil
        }
        return connection
    }

    private func setFocusedConnection(
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

    private func removeAllControlSubscriptions() {
        let controlIDs = entriesByMacDeviceID.compactMap { macDeviceID, entry in
            if case .control = entry { return macDeviceID }
            return nil
        }
        for macDeviceID in controlIDs {
            entriesByMacDeviceID[macDeviceID] = nil
        }
    }

    private func removeAllFocusedConnections() {
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
