#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `turn` checkpoints: at the end of every outermost perform turn it
/// reads the armed main-actor facets and keeps their values in a ring of 256 (``OracleTurnRing``),
/// read back by `debug.oracle.turns`. The runner arms it, runs a step, then marks the settled state,
/// normalizes both checkpoints with normalize.py, and invariant I3 compares the two projections.
///
/// The App's composition root makes one and hands it to its action registry as the registry's
/// perform-turn observer, in DEV and bench builds only; Release has no recorder, so its perform pays
/// one nil check. Disarmed (the default), a turn costs one optional check here. Armed, a turn costs
/// the read of its armed facets, inside the action's turn: a run that arms the recorder does not
/// check the action budget invariants (p15-oracle.md, I11-I14).
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

    /// Applies `request` whole or not at all: everything that can fail is checked before anything
    /// changes, then the ring is cleared, the recorder armed or disarmed, and the mark recorded, in
    /// that order. Returns the last checkpoint it recorded (the `armed` mark or the request's mark).
    @discardableResult
    public func apply(_ request: OracleRecorderRequest) throws(OracleRecorderError) -> OracleCheckpoint? {
        var next = armed
        var armedValues: OracleValue?
        switch request.arming {
        case .arm(let facets, let requested)?:
            armedValues = try Self.armableValues(facets, requested)
            next = Armed(facets: facets, requested: requested)
        case .disarm?:
            next = nil
        case nil:
            break
        }
        if request.mark != nil, next == nil { throw .notArmed }

        if request.clear { ring.clear() }
        armed = next
        var checkpoint: OracleCheckpoint?
        if let armedValues { checkpoint = ring.append(kind: .mark, label: "armed", facets: armedValues) }
        if let label = request.mark, let next { checkpoint = record(.mark, label: label, origin: nil, ran: nil, next) }
        return checkpoint
    }

    /// Arms the recorder with `requested` from `facets` and records the `armed` mark, the state
    /// before the first turn. A turn is read inside its own main-actor turn, so a facet read off the
    /// main actor cannot be in a turn checkpoint: arming with one fails and leaves the recorder as it was.
    @discardableResult
    public func arm(_ facets: OracleFacets, requested: [OracleFacet]) throws(OracleRecorderError) -> OracleCheckpoint {
        let values = try Self.armableValues(facets, requested)
        armed = Armed(facets: facets, requested: requested)
        return ring.append(kind: .mark, label: "armed", facets: values)
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
                // Arming refuses such a facet and the list is immutable; recorded, never as an empty snapshot.
                return ring.append(kind: kind, label: label, origin: origin, ran: ran, facets: nil,
                                   failure: OracleRecorderError.backgroundFacet.message)
            }
            return ring.append(kind: kind, label: label, origin: origin, ran: ran, facets: values)
        } catch {
            return ring.append(kind: kind, label: label, origin: origin, ran: ran, facets: nil, failure: error.message)
        }
    }

    /// The facets an arm would record, read now; fails when one is read off the main actor or a provider fails.
    private static func armableValues(_ facets: OracleFacets,
                                      _ requested: [OracleFacet]) throws(OracleRecorderError) -> OracleValue {
        let values: OracleValue?
        do throws(OracleSnapshotError) {
            values = try mainActorValues(facets, requested)
        } catch {
            throw .facetFailed(error.message)
        }
        guard let values else { throw .backgroundFacet }
        return values
    }

    /// The requested facets read in this turn as `{<facet>: <value>}`, or nil when one of them is read
    /// off the main actor.
    private static func mainActorValues(_ facets: OracleFacets,
                                        _ requested: [OracleFacet]) throws(OracleSnapshotError) -> OracleValue? {
        guard case .object(let values)? = try facets.beginCapture(requested).completed else { return nil }
        return .object(values)
    }
}

/// One `debug.oracle.recorder` request, applied whole or not at all by ``OracleTurnRecorder/apply(_:)``.
public struct OracleRecorderRequest: Sendable {
    /// Arm with facets from a list, or disarm.
    public enum Arming: Sendable {
        case arm(OracleFacets, [OracleFacet])
        case disarm
    }

    /// Empty the ring first.
    public var clear: Bool
    /// Arm or disarm; nil leaves the recorder armed or disarmed as it is.
    public var arming: Arming?
    /// Record a mark with this label last; the recorder must be armed after ``arming``.
    public var mark: String?

    public init(clear: Bool = false, arming: Arming? = nil, mark: String? = nil) {
        self.clear = clear
        self.arming = arming
        self.mark = mark
    }
}

/// A `debug.oracle.recorder` request the recorder cannot do.
public enum OracleRecorderError: Error, Sendable, Hashable {
    /// `mark` while the recorder is not armed, or in the request that disarms it.
    case notArmed
    /// A requested facet is read off the main actor, so no turn can read it.
    case backgroundFacet
    /// A provider failed while arming.
    case facetFailed(String)

    public var message: String {
        switch self {
        case .notArmed: "the oracle recorder is not armed; a mark needs an armed recorder"
        case .backgroundFacet: "a turn checkpoint reads main-actor facets only; name them in facets"
        case .facetFailed(let message): message
        }
    }
}
#endif
