import Foundation
import Observation

/// Owns optimistic machine deletion: which machines every list hides while a
/// destroy is in flight, and which confirmed deletions stay hidden.
///
/// Begin before starting I/O, then report the authoritative outcome. A confirmed
/// deletion stays hidden until the account ends: provider machine IDs are never
/// reused, and any list may still hold a read that started before confirmation.
///
/// ```swift
/// let deletions = CloudMachineDeletionCoordinator()
/// guard deletions.begin("m1") else { return }  // false: already deleting
/// _ = deletions.finish("m1", result: .deleted)  // m1 stays hidden
/// ```
@MainActor
@Observable
public final class CloudMachineDeletionCoordinator {
    /// An immutable snapshot shared by every list, independent of rendering cadence.
    public private(set) var projection = CloudMachineDeletionProjection()

    @ObservationIgnored private var entries: [String: Entry] = [:]

    private enum Entry: Equatable {
        /// Hidden for a cancelled create's cleanup whose destroy request has not started.
        case awaitingRequest
        /// The destroy request has not reported an outcome.
        case pending
        /// Confirmed gone; hidden until the account ends.
        case deleted
    }

    /// Creates an empty owner for one application session.
    public init() {}

    /// Reports whether the machine's deletion still awaits an outcome, including a
    /// cleanup whose destroy request has not started.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False once an outcome arrived or the account ended.
    public func isPending(_ machineID: String) -> Bool {
        entries[machineID] == .pending || entries[machineID] == .awaitingRequest
    }

    /// Hides the machine from every list before any destroy request starts.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False when the machine is already being or has been deleted.
    @discardableResult
    public func begin(_ machineID: String) -> Bool {
        begin(machineID, as: .pending)
    }

    /// Hides the machine a cancelled create announced, for that create's cleanup.
    /// Its presentations stay until ``beginRequest(_:)`` reports the cleanup's request.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False when the machine is already being or has been deleted.
    @discardableResult
    public func beginCleanup(_ machineID: String) -> Bool {
        begin(machineID, as: .awaitingRequest)
    }

    /// Records that a destroy request for the machine starts.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: True only for a cleanup's first request, when the caller detaches
    ///   the machine's presentations.
    public func beginRequest(_ machineID: String) -> Bool {
        guard entries[machineID] == .awaitingRequest else { return false }
        entries[machineID] = .pending
        return true
    }

    private func begin(_ machineID: String, as entry: Entry) -> Bool {
        guard !machineID.isEmpty, entries[machineID] == nil else { return false }
        entries[machineID] = entry
        var next = projection
        next.hiddenMachineIDs.insert(machineID)
        next.pendingMachineIDs.insert(machineID)
        projection = next
        return true
    }

    /// Commits the authoritative outcome of the machine's destroy request.
    /// - Parameters:
    ///   - machineID: The machine whose request finished.
    ///   - result: The provider's answer.
    /// - Returns: Effects to apply, or ``CloudMachineDeletionTransition/ignored``
    ///   for a duplicate outcome or one that outlived its account.
    public func finish(_ machineID: String, result: CloudMachineDeletionResult) -> CloudMachineDeletionTransition {
        guard isPending(machineID) else { return .ignored }
        var next = projection
        next.pendingMachineIDs.remove(machineID)
        let transition: CloudMachineDeletionTransition
        switch result {
        case .deleted, .notFound:
            entries[machineID] = .deleted
            transition = .retired
        case .failed:
            entries[machineID] = nil
            next.hiddenMachineIDs.remove(machineID)
            transition = .restored
        }
        projection = next
        return transition
    }

    /// Forgets every deletion when the account or team changes. Outcomes that
    /// arrive later are ignored, so a departed account never rolls back a row.
    /// - Returns: Whether any deletion was forgotten.
    @discardableResult
    public func endAccount() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeAll()
        projection = CloudMachineDeletionProjection()
        return true
    }
}
