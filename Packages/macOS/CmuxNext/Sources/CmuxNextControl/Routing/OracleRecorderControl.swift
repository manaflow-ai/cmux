#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextActions
public import CmuxNextOracle
import CmuxNextSettings

/// The turn recorder as the action registry's perform-turn observer: the App's composition root makes
/// one and passes it to `ActionRegistry.standard(runTiming:turnObserver:)` and to
/// ``OracleControl/methods(host:turns:)``, in DEV and bench builds only.
@MainActor
public final class OracleActionTurns: ActionRunObserver {
    public let recorder: OracleTurnRecorder

    public init(recorder: OracleTurnRecorder = OracleTurnRecorder()) {
        self.recorder = recorder
    }

    public func performTurnEnded(_ turn: ActionTurn) {
        recorder.turnEnded(action: turn.id.rawValue, origin: turn.origin.rawValue, ran: turn.ran)
    }
}

/// `debug.oracle.recorder` and `debug.oracle.turns` (p15-oracle-032) over the one turn recorder and
/// facet list a composition root built. DEV and bench builds only, like ``OracleControl``: a Release
/// router answers both names `not_allowed`.
public struct OracleRecorderControl: Sendable {
    public static let recorder = "debug.oracle.recorder"
    public static let turns = "debug.oracle.turns"

    public let turnRecorder: OracleTurnRecorder
    public let facets: OracleFacets

    public init(recorder: OracleTurnRecorder, facets: OracleFacets) {
        turnRecorder = recorder
        self.facets = facets
    }

    public var methods: [ControlMethod] {
        [
            // Params, applied in this order: `clear` (empty the ring), `arm` (true: arm with `facets`, the
            // facet names, all when absent; false: disarm), `mark` (a label: record a checkpoint of the
            // armed facets now, the runner's `settled`). The result is the status, plus `checkpoint` for
            // an arm or a mark.
            .mainActor(Self.recorder) { [turnRecorder, facets] call in
                .value(try Self.answer(call.params, recorder: turnRecorder, facets: facets))
            },
            // Params: `after` (a sequence: only later checkpoints), `last` (at most this many, the newest).
            // The result is the status and `checkpoints`, oldest first.
            .mainActor(Self.turns) { [turnRecorder] call in
                let after = try Self.count(call.params["after"], name: "after")
                let last = try Self.count(call.params["last"], name: "last")
                let checkpoints = turnRecorder.ring.checkpoints(after: after.map { UInt64(truncatingIfNeeded: $0) }, last: last)
                return .value(Self.status(turnRecorder, adding: "checkpoints", .array(checkpoints.map(\.value))))
            },
        ]
    }

    @MainActor
    private static func answer(_ params: [String: JSONValue], recorder: OracleTurnRecorder,
                               facets: OracleFacets) throws(ControlError) -> JSONValue {
        let arming = params["arm"]?.boolValue
        let armFacets = try arming == true ? requested(params["facets"]) : []
        if params["clear"]?.boolValue == true { recorder.clear() }
        var checkpoint: OracleCheckpoint?
        do throws(OracleRecorderError) {
            switch arming {
            case true?: checkpoint = try recorder.arm(facets, requested: armFacets)
            case false?: recorder.disarm()
            case nil: break
            }
            if let label = params["mark"]?.stringValue { checkpoint = try recorder.mark(label) }
        } catch {
            throw ControlError.invalidParams(error.message)
        }
        return status(recorder, adding: "checkpoint", checkpoint?.value)
    }

    /// The recorder's status with `value` under `key` (nothing added when nil).
    @MainActor
    private static func status(_ recorder: OracleTurnRecorder, adding key: String, _ value: OracleValue?) -> JSONValue {
        guard case .object(var members) = recorder.status else { return .null }
        if let value { members[key] = value }
        return OracleControl.json(.object(members))
    }

    /// The `facets` param: every facet when absent, else the named ones.
    private static func requested(_ param: JSONValue?) throws(ControlError) -> [OracleFacet] {
        guard let param, !param.isNull else { return OracleFacet.allCases }
        let names = param.arrayValue?.compactMap(\.stringValue)
        guard let names, names.count == param.arrayValue?.count else {
            throw ControlError.invalidParams(OracleRequestError.notAList.message, data: ["param": "facets"])
        }
        do throws(OracleRequestError) {
            return try OracleFacets.requested(names)
        } catch {
            throw ControlError.invalidParams(error.message, data: ["param": "facets"])
        }
    }

    /// A non-negative integer param, or nil when absent.
    private static func count(_ param: JSONValue?, name: String) throws(ControlError) -> Int? {
        guard let param, !param.isNull else { return nil }
        guard let value = param.intValue, value >= 0 else {
            throw ControlError.invalidParams("\(name) must be a non-negative integer", data: ["param": .string(name)])
        }
        return value
    }
}

extension OracleControl {
    /// Every `debug.oracle.*` method over the host's one facet list: `debug.oracle.snapshot` and the
    /// turn recorder's `debug.oracle.recorder` and `debug.oracle.turns`.
    @MainActor
    public static func methods(host: some OracleHost, turns: OracleActionTurns) -> [ControlMethod] {
        let snapshot = OracleControl(host: host)
        return snapshot.methods + OracleRecorderControl(recorder: turns.recorder, facets: snapshot.facets).methods
    }
}
#endif
