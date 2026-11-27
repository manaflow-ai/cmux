public import Foundation

/// Decides whether this launch may overwrite the primary session snapshot.
///
/// A launch that restored less than the snapshot it started from (a failed
/// restore, an explicit-open launch, a relaunch by a tool) must not replace
/// the richer snapshot straight away: two quick restarts would otherwise
/// leave only the trivial layout on disk. Writes are held until the session
/// matures, which happens once any of these holds:
///
/// - the candidate snapshot is at least as rich as the launch baseline,
/// - the session has lived for `maturityInterval`,
/// - the workspace/panel structure changed after the first saved snapshot
///   (the user, or an agent acting for them, changed the layout).
///
/// Maturity latches for the rest of the process.
public struct SessionSnapshotOverwriteGuard: Sendable {
    public enum Decision: Equatable, Sendable {
        case write
        case hold
    }

    public static let defaultMaturityInterval: TimeInterval = 5 * 60

    public let baseline: SessionSnapshotRichness
    public let launchDate: Date
    public let maturityInterval: TimeInterval
    public private(set) var isMature: Bool
    private var firstStructure: Int?

    public init(
        baseline: SessionSnapshotRichness,
        launchDate: Date,
        maturityInterval: TimeInterval = SessionSnapshotOverwriteGuard.defaultMaturityInterval
    ) {
        self.baseline = baseline
        self.launchDate = launchDate
        self.maturityInterval = maturityInterval
        self.isMature = false
        self.firstStructure = nil
    }

    /// - Parameters:
    ///   - candidate: Richness of the snapshot about to be written.
    ///   - structure: A hash of the workspace and panel identities in the
    ///     candidate. Only equality between calls matters.
    ///   - now: The current time.
    public mutating func evaluate(
        candidate: SessionSnapshotRichness,
        structure: Int,
        now: Date
    ) -> Decision {
        if isMature { return .write }
        if candidate >= baseline || now.timeIntervalSince(launchDate) >= maturityInterval {
            isMature = true
            return .write
        }
        guard let firstStructure else {
            self.firstStructure = structure
            return .hold
        }
        if structure != firstStructure {
            isMature = true
            return .write
        }
        return .hold
    }
}
