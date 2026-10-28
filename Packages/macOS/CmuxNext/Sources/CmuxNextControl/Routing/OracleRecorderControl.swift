#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextActions
public import CmuxNextOracle
public import Observation
import CmuxNextSettings

/// The turn recorder as the action registry's perform-turn observer: the App's composition root makes
/// one and passes it to `ActionRegistry.standard(runTiming:turnObserver:)` and to
/// ``OracleControl/methods(host:turns:)``, in DEV and bench builds only.
///
/// It also counts the refused turns since launch for the `intents` facet (``OracleIntentsFacet``): a turn
/// whose action did not run (`ran` false: a disabled feature, an unavailable or disabled action, a refused
/// target) or whose handler refused (``noteRefusal()``). Observed, so `debug.oracle.wait_for` hears one.
@MainActor @Observable
public final class OracleActionTurns: ActionRunObserver {
    @ObservationIgnored public let recorder: OracleTurnRecorder
    /// Refused perform turns since launch; only grows (the runner diffs two checkpoints).
    public private(set) var refusedTurns = 0
    /// The canonical action id of the last refused turn: the action the person or script ran, never the
    /// reason, which is localized and can hold a name.
    public private(set) var lastRefusedAction: String?
    /// A handler of the turn in progress has started (``runStarted()``), so a refusal now is that turn's.
    @ObservationIgnored private var inRun = false
    @ObservationIgnored private var refusedInRun = false

    public init(recorder: OracleTurnRecorder = OracleTurnRecorder()) {
        self.recorder = recorder
    }

    /// The registry is about to run a handler (its `willRunObservers`).
    public func runStarted() {
        inRun = true
    }

    /// The registry reported a refusal (its `refusalObserver`). Outside a handler run, after its turn
    /// ended (a task the handler started), it belongs to no turn and is not counted.
    public func noteRefusal() {
        if inRun { refusedInRun = true }
    }

    public func performTurnEnded(_ turn: ActionTurn) {
        if !turn.ran || refusedInRun {
            refusedTurns += 1
            lastRefusedAction = turn.id.rawValue
        }
        inRun = false
        refusedInRun = false
        recorder.turnEnded(action: turn.id.rawValue, origin: turn.origin.rawValue, ran: turn.ran)
    }
}

/// `debug.oracle.recorder` and `debug.oracle.turns` over the one turn recorder and
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
            // Params: `clear` (empty the ring), `arm` (true: arm with `facets`, the facet names, all when
            // absent, and `paths`, the prefixes hashed path fields rewrite as `debug.oracle.snapshot` does; false:
            // disarm), `mark` (a label: record a checkpoint of the armed facets now, the
            // runner's `settled`). Applied whole or not at all: a refused request changes nothing, and an
            // accepted one clears, then arms or disarms, then marks. The result is the status, plus
            // `checkpoint` for an arm or a mark.
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
        let request = try Self.request(params, facets: facets)
        let checkpoint: OracleCheckpoint?
        do throws(OracleRecorderError) {
            checkpoint = try recorder.apply(request)
        } catch {
            throw ControlError.invalidParams(error.message)
        }
        return status(recorder, adding: "checkpoint", checkpoint?.value)
    }

    /// The `debug.oracle.recorder` params as one request. Refuses a param of the wrong type and
    /// `facets` or `paths` without `arm: true`; the recorder refuses the rest before it changes anything.
    private static func request(_ params: [String: JSONValue],
                                facets: OracleFacets) throws(ControlError) -> OracleRecorderRequest {
        let clear = try flag(params["clear"], name: "clear") ?? false
        let arm = try flag(params["arm"], name: "arm")
        let mark = try label(params["mark"])
        let arming: OracleRecorderRequest.Arming?
        switch arm {
        case true?:
            arming = try .arm(facets.rewriting(OracleControl.paths(params["paths"])), requested(params["facets"]))
        case false?, nil:
            for name in ["facets", "paths"] {
                if let value = params[name], !value.isNull {
                    throw ControlError.invalidParams("\(name) needs arm: true", data: ["param": .string(name)])
                }
            }
            arming = arm == false ? .disarm : nil
        }
        return OracleRecorderRequest(clear: clear, arming: arming, mark: mark)
    }

    /// A boolean param, or nil when absent.
    private static func flag(_ param: JSONValue?, name: String) throws(ControlError) -> Bool? {
        guard let param, !param.isNull else { return nil }
        guard let value = param.boolValue else {
            throw ControlError.invalidParams("\(name) must be a boolean", data: ["param": .string(name)])
        }
        return value
    }

    /// The `mark` label, or nil when absent.
    private static func label(_ param: JSONValue?) throws(ControlError) -> String? {
        guard let param, !param.isNull else { return nil }
        guard let value = param.stringValue else {
            throw ControlError.invalidParams("mark must be a string", data: ["param": "mark"])
        }
        return value
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
    /// Every `debug.oracle.*` method over the host's one facet list and the router's topology
    /// (`snapshots`): `debug.oracle.snapshot` and the turn recorder's `debug.oracle.recorder` and
    /// `debug.oracle.turns`.
    @MainActor
    public static func methods(host: some OracleHost, snapshots: ControlSnapshotStore,
                               turns: OracleActionTurns) -> [ControlMethod] {
        let snapshot = OracleControl(host: host, snapshots: snapshots)
        return snapshot.methods + OracleRecorderControl(recorder: turns.recorder, facets: snapshot.facets).methods
    }
}
#endif
