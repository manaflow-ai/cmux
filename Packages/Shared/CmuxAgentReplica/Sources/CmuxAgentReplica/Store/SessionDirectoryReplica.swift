import Foundation
public import Observation

/// Maintains replicated session metadata for one Mac.
@MainActor @Observable public final class SessionDirectoryReplica {
    /// The current epoch for the directory.
    public private(set) var epoch: ReplicaEpoch?
    /// The last origin observed by ``apply(_:origin:)`` or ``replaceAll(_:epoch:)``.
    public private(set) var lastAppliedOrigin: DeltaOrigin?

    private var snapshotsByID: [AgentSessionID: AgentSessionSnapshot]
    private var versionsByID: [AgentSessionID: EntityVersion]

    /// Creates an empty session directory replica.
    /// - Parameter epoch: The initial epoch, if known.
    public init(epoch: ReplicaEpoch? = nil) {
        self.epoch = epoch
        snapshotsByID = [:]
        versionsByID = [:]
    }

    /// Sessions sorted for display by urgency and recency hint.
    public var sessions: [AgentSessionSnapshot] {
        snapshotsByID.values.sorted { lhs, rhs in
            let leftRank = Self.phaseRank(lhs.phase)
            let rightRank = Self.phaseRank(rhs.phase)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if lhs.lastActivityHint != rhs.lastActivityHint {
                return lhs.lastActivityHint > rhs.lastActivityHint
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    /// Applies one directory-relevant delta using entity-version gating.
    /// - Parameters:
    ///   - delta: The incoming mutation.
    ///   - origin: The mutation origin to expose to observers.
    public func apply(_ delta: ReplicaDelta, origin: DeltaOrigin) {
        switch delta {
        case .sessionUpserted(let snapshot):
            guard shouldApply(id: snapshot.id, version: snapshot.version) else {
                return
            }
            snapshotsByID[snapshot.id] = snapshot
            versionsByID[snapshot.id] = snapshot.version
            lastAppliedOrigin = origin
        case .sessionRemoved(let id, let version):
            guard shouldApply(id: id, version: version) else {
                return
            }
            snapshotsByID[id] = nil
            versionsByID[id] = version
            lastAppliedOrigin = origin
        default:
            return
        }
    }

    /// Replaces the directory from a pull and resets version gates.
    /// - Parameters:
    ///   - snapshots: The pulled session snapshots.
    ///   - epoch: The epoch that produced the pull.
    public func replaceAll(_ snapshots: [AgentSessionSnapshot], epoch: ReplicaEpoch) {
        self.epoch = epoch
        lastAppliedOrigin = .resync
        snapshotsByID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { existing, incoming in
            incoming.version > existing.version ? incoming : existing
        })
        versionsByID = snapshotsByID.mapValues(\.version)
    }

    /// Applies the epoch-change drop rule for session metadata.
    /// - Parameter epoch: The new Mac app epoch.
    public func handleEpochChange(to epoch: ReplicaEpoch) {
        guard self.epoch != epoch else {
            return
        }
        self.epoch = epoch
        snapshotsByID.removeAll()
        versionsByID.removeAll()
        lastAppliedOrigin = .resync
    }

    private func shouldApply(id: AgentSessionID, version: EntityVersion) -> Bool {
        guard let previous = versionsByID[id] else {
            return true
        }
        return version > previous
    }

    private static func phaseRank(_ phase: SessionPhase) -> Int {
        switch phase {
        case .needsInput: 0
        case .working: 1
        case .idle, .starting, .unknown: 2
        case .ended: 3
        }
    }
}
