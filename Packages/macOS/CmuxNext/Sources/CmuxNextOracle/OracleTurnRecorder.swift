#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `turn` checkpoints (p15-oracle-032): at the end of every outermost perform turn it
/// reads the armed main-actor facets and keeps their hashes in a ring of 256 (``OracleTurnRing``),
/// read back by `debug.oracle.turns`. The runner arms it, runs a step, then marks the settled state,
/// and invariant I3 compares the two hashes.
///
/// The App's composition root makes one and hands it to its action registry as the registry's
/// perform-turn observer, in DEV and bench builds only; Release has no recorder, so its perform pays
/// one nil check. Disarmed (the default), a turn costs one optional check here.
///
/// As in Chromium's interaction tests (chrome/test/interaction/README.md), a checkpoint is taken at a
/// named event, the end of the action's turn, never after a sleep or an idle wait.
@MainActor
public final class OracleTurnRecorder {
    /// The facets a turn checkpoint reads and the list that reads them.
    private struct Armed {
        let facets: OracleFacets
        let requested: [OracleFacet]
    }

    private var armed: Armed?
    public private(set) var ring: OracleTurnRing

    public init(capacity: Int = OracleTurnRing.defaultCapacity) {
        ring = OracleTurnRing(capacity: capacity)
    }

    public var isArmed: Bool { armed != nil }
    public var armedFacets: [OracleFacet] { armed?.requested ?? [] }

    /// The end of an outermost perform turn of `action`, started by `origin`; `ran` is false for a refused run.
    public func turnEnded(action: String, origin: String, ran: Bool) {
        guard let armed else { return }
        record(.turn, label: action, origin: origin, ran: ran, armed)
    }

    /// Arms the recorder with `requested` from `facets` and records the `armed` mark, the state
    /// before the first turn. A turn is read inside its own main-actor turn, so a facet read off the
    /// main actor cannot be in a turn checkpoint: arming with one fails and leaves the recorder as it was.
    @discardableResult
    public func arm(_ facets: OracleFacets, requested: [OracleFacet]) throws(OracleRecorderError) -> OracleCheckpoint {
        let values: [String: OracleValue]?
        do throws(OracleSnapshotError) {
            values = try Self.mainActorValues(facets, requested)
        } catch {
            throw .facetFailed(error.message)
        }
        guard let values else { throw .backgroundFacet }
        armed = Armed(facets: facets, requested: requested)
        return ring.append(kind: .mark, label: "armed", snapshot: OracleSnapshotHash(values))
    }

    public func disarm() {
        armed = nil
    }

    /// Records a `mark` checkpoint of the armed facets now (the runner's `settled`, after `debug.oracle.settle`).
    public func mark(_ label: String) throws(OracleRecorderError) -> OracleCheckpoint {
        guard let armed else { throw .notArmed }
        return record(.mark, label: label, origin: nil, ran: nil, armed)
    }

    public func clear() {
        ring.clear()
    }

    /// The `debug.oracle.recorder` status.
    public var status: OracleValue {
        [
            "armed": .bool(isArmed),
            "facets": .array(armedFacets.map { .string($0.rawValue) }),
            "capacity": OracleValue(ring.capacity),
            "count": OracleValue(ring.count),
            "nextSequence": .number(Double(ring.nextSequence)),
            "dropped": .number(Double(ring.dropped)),
        ]
    }

    @discardableResult
    private func record(_ kind: OracleCheckpoint.Kind, label: String, origin: String?, ran: Bool?,
                        _ armed: Armed) -> OracleCheckpoint {
        do throws(OracleSnapshotError) {
            guard let values = try Self.mainActorValues(armed.facets, armed.requested) else {
                // Arming refuses such a facet and the list is immutable; recorded, never hashed as empty.
                return ring.append(kind: kind, label: label, origin: origin, ran: ran, snapshot: nil,
                                   failure: OracleRecorderError.backgroundFacet.message)
            }
            return ring.append(kind: kind, label: label, origin: origin, ran: ran, snapshot: OracleSnapshotHash(values))
        } catch {
            return ring.append(kind: kind, label: label, origin: origin, ran: ran, snapshot: nil, failure: error.message)
        }
    }

    /// The requested facets read in this turn, or nil when one of them is read off the main actor.
    private static func mainActorValues(_ facets: OracleFacets,
                                        _ requested: [OracleFacet]) throws(OracleSnapshotError) -> [String: OracleValue]? {
        guard case .object(let values)? = try facets.beginCapture(requested).completed else { return nil }
        return values
    }
}

/// A `debug.oracle.recorder` request the recorder cannot do.
public enum OracleRecorderError: Error, Sendable, Hashable {
    /// `mark` before `arm`.
    case notArmed
    /// A requested facet is read off the main actor, so no turn can read it.
    case backgroundFacet
    /// A provider failed while arming.
    case facetFailed(String)

    public var message: String {
        switch self {
        case .notArmed: "the oracle recorder is not armed"
        case .backgroundFacet: "a turn checkpoint reads main-actor facets only; name them in facets"
        case .facetFailed(let message): message
        }
    }
}
#endif
