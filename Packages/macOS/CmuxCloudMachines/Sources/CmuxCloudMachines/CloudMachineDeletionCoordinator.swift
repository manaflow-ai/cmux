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
        /// The destroy request has not reported an outcome.
        case pending
        /// Confirmed gone; hidden until the account ends.
        case deleted
    }

    /// Creates an empty owner for one application session.
    public init() {}

    /// Reports whether a destroy request for the machine still awaits its outcome.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False once an outcome arrived or the account ended.
    public func isPending(_ machineID: String) -> Bool {
        entries[machineID] == .pending
    }

    /// Hides the machine from every list before any destroy request starts.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False when the machine is already being or has been deleted.
    @discardableResult
    public func begin(_ machineID: String) -> Bool {
        guard !machineID.isEmpty, entries[machineID] == nil else { return false }
        entries[machineID] = .pending
        projection.hiddenMachineIDs.insert(machineID)
        return true
    }

    /// Commits the authoritative outcome of the machine's destroy request.
    /// - Parameters:
    ///   - machineID: The machine whose request finished.
    ///   - result: The provider's answer.
    /// - Returns: Effects to apply, or ``CloudMachineDeletionTransition/ignored``
    ///   for a duplicate outcome or one that outlived its account.
    public func finish(_ machineID: String, result: CloudMachineDeletionResult) -> CloudMachineDeletionTransition {
        guard entries[machineID] == .pending else { return .ignored }
        switch result {
        case .deleted, .notFound:
            entries[machineID] = .deleted
            return .retired
        case .failed:
            entries[machineID] = nil
            projection.hiddenMachineIDs.remove(machineID)
            return .restored
        }
    }

    /// Forgets every deletion when the account or team changes. Outcomes that
    /// arrive later are ignored, so a departed account never rolls back a row.
    /// - Returns: Whether the hidden set changed.
    @discardableResult
    public func endAccount() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeAll()
        projection.hiddenMachineIDs.removeAll()
        return true
    }
}
