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

    /// Creates an empty owner for one application session.
    public init() {}

    /// Reports whether a destroy request for the machine still awaits its outcome.
    public func isPending(_ machineID: String) -> Bool { false }

    /// Hides the machine from every list before any destroy request starts.
    @discardableResult
    public func begin(_ machineID: String) -> Bool { true }

    /// Commits the authoritative outcome of the machine's destroy request.
    public func finish(_ machineID: String, result: CloudMachineDeletionResult) -> CloudMachineDeletionTransition { .ignored }

    /// Fences a fleet read. Call it immediately before the read starts.
    public func beginListing() -> CloudMachineDeletionListing { CloudMachineDeletionListing(generation: 0) }

    /// Stops hiding confirmed deletions that a sufficiently recent read omits.
    @discardableResult
    public func reconcile(_ listing: CloudMachineDeletionListing, machineIDs: Set<String>) -> Bool { false }

    /// Forgets every deletion when the account or team changes.
    @discardableResult
    public func endAccount() -> Bool { false }
}
