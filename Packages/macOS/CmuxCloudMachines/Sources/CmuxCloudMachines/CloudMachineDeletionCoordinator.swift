import Foundation
import Observation

/// Owns optimistic machine deletion: which machines every list hides while a
/// destroy is in flight, and which confirmed deletions stay hidden until the
/// fleet agrees.
///
/// Begin before starting I/O, then report the authoritative outcome. Take a
/// listing fence before every fleet read and reconcile the result with it:
///
/// ```swift
/// let deletions = CloudMachineDeletionCoordinator()
/// guard deletions.begin("m1") else { return }  // false: already deleting
/// let listing = deletions.beginListing()
/// _ = deletions.finish("m1", result: .deleted)
/// deletions.reconcile(listing, machineIDs: [])  // read began first: still hidden
/// ```
@MainActor
@Observable
public final class CloudMachineDeletionCoordinator {
    /// An immutable snapshot shared by every list, independent of rendering cadence.
    public private(set) var projection = CloudMachineDeletionProjection()

    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var listingGeneration: UInt64 = 0

    private enum Entry: Equatable {
        /// The destroy request has not reported an outcome.
        case pending
        /// Confirmed gone; hidden until a read started after `generation` omits it.
        case deleted(generation: UInt64)
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
            entries[machineID] = .deleted(generation: listingGeneration)
            return .retired
        case .failed:
            entries[machineID] = nil
            projection.hiddenMachineIDs.remove(machineID)
            return .restored
        }
    }

    /// Fences a fleet read. Call it immediately before the read starts.
    /// - Returns: The token to pass to ``reconcile(_:machineIDs:)`` with the result.
    public func beginListing() -> CloudMachineDeletionListing {
        listingGeneration &+= 1
        return CloudMachineDeletionListing(generation: listingGeneration)
    }

    /// Stops hiding confirmed deletions that a sufficiently recent read omits.
    ///
    /// Pending deletions stay hidden whatever the read contains, and a read that
    /// started before a confirmation cannot retire it, so neither a stale poll nor
    /// a lagging backend can show a deleted machine again.
    /// - Parameters:
    ///   - listing: The fence taken when the read started.
    ///   - machineIDs: Every machine the read returned.
    /// - Returns: Whether the hidden set changed.
    @discardableResult
    public func reconcile(_ listing: CloudMachineDeletionListing, machineIDs: Set<String>) -> Bool {
        let retired = entries.compactMap { id, entry -> String? in
            guard case .deleted(let generation) = entry, listing.generation > generation,
                  !machineIDs.contains(id) else { return nil }
            return id
        }
        guard !retired.isEmpty else { return false }
        for id in retired { entries[id] = nil }
        projection.hiddenMachineIDs.subtract(retired)
        return true
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
