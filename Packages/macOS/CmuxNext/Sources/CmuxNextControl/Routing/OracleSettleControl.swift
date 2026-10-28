#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle
import CmuxNextSettings
import Observation

/// `debug.oracle.settle` and `debug.oracle.wait_for` (p15-oracle.md section 3B), DEV and bench builds only:
/// a Release router drops every `debug.*` registration (``ControlRouter/debugMethodsAllowed``).
///
/// - `debug.oracle.settle {sequence, settleMaxMs}`: the checkpoint barrier (``ControlRouter/oracleSettle(after:sources:deadline:)``).
///   `sequence` is a home daemon event sequence or `"sync"` (the default). Answers
///   `{settled, pending, sequence, elapsed_ms}`; a missed `settleMaxMs` is `settled: false` with the pending list.
/// - `debug.oracle.wait_for {pointer, equals | predicate, since, maxMs}` (schemas/oracle/case-v1.schema.json
///   `$defs/waitFor`; `since` is the runner's): reads the pointer's facet, then again on each change signal of
///   that facet (the Observation of what a main-actor provider read, a background provider's
///   ``OracleFacetProvider/changes``, and each control snapshot publish) until the condition holds. Answers
///   `{satisfied, value, evaluations, elapsed_ms}`, plus `pending: [pointer]` when `maxMs` passed first.
public struct OracleSettleControl: Sendable {
    public static let settle = "debug.oracle.settle"
    public static let waitFor = "debug.oracle.wait_for"
    /// `settleMaxMs` when the request gives none.
    public static let defaultSettleMilliseconds = 5_000
    /// The case schema's `settleMaxMs` maximum (60,000) times 5: a `Slow` expectation multiplies the case's
    /// bound by 5 (p15-oracle.md 3E, expectations.py rule 16).
    public static let maxSettleMilliseconds = 300_000
    /// The router's own deadline is this much later than the request's bound, so the bound answers first.
    static let replyMargin: Duration = .seconds(1)

    /// The settle stages, as the pending list names them.
    enum Stage {
        static let sync = "control.sync"
        static let snapshot = "control.snapshot"
        static let motion = "motion"
        static let commit = "commit"
    }

    private weak var router: ControlRouter?
    private let facets: OracleFacets
    private let sources: OracleSettleSources

    public init(router: ControlRouter, facets: OracleFacets, sources: OracleSettleSources) {
        self.router = router
        self.facets = facets
        self.sources = sources
    }

    public var methods: [ControlMethod] {
        [
            .async(Self.settle) { [weak router, sources] call in
                guard let router else { throw ControlError(code: "unavailable", message: "control router is gone") }
                let bound = try Self.settleBound(call.params)
                let started = ContinuousClock.now
                let outcome = try await router.oracleSettle(after: call.params["sequence"] ?? .string("sync"), sources: sources,
                                                            deadline: started + bound)
                var reply: [String: JSONValue] = [
                    "settled": .bool(outcome.settled),
                    "pending": .array(outcome.pending.map(JSONValue.string)),
                    "elapsed_ms": JSONValue((ContinuousClock.now - started).wholeMilliseconds),
                ]
                if let sequence = outcome.sequence { reply["sequence"] = .number(Double(sequence)) }
                return .object(reply)
            }.withLimit { request, _ in (try? Self.settleBound(request.params)).map { $0 + Self.replyMargin } },
            .async(Self.waitFor) { [weak router, facets] call in
                guard let router else { throw ControlError(code: "unavailable", message: "control router is gone") }
                let condition: OracleWaitCondition
                do throws(OracleWaitConditionError) {
                    condition = try OracleWaitCondition(params: call.params)
                } catch {
                    throw ControlError.invalidParams(error.message, data: ["param": .string(error.param)])
                }
                guard facets.provided.contains(condition.facet) else {
                    throw ControlError(code: "unavailable", message: "no provider for facet \(condition.facet.rawValue) in this build",
                                       data: ["facet": .string(condition.facet.rawValue), "task": .string(condition.facet.task)])
                }
                // A background facet read once and never again would end every wait on it as a false Timeout.
                guard facets.signalsChanges(condition.facet) else {
                    throw ControlError(code: "unavailable", message: "facet \(condition.facet.rawValue) gives no change signal to wait on in this build",
                                       data: ["facet": .string(condition.facet.rawValue), "reason": "no_change_signal"])
                }
                // `paths`, as `debug.oracle.snapshot` takes it: a wait on a hashed path field compares the same hash.
                let rewriting = facets.rewriting(try OracleControl.paths(call.params["paths"]))
                let started = ContinuousClock.now
                let outcome = try await Self.awaitCondition(condition, facets: rewriting, snapshots: router.snapshots,
                                                            deadline: started + condition.limit)
                var reply: [String: JSONValue] = [
                    "satisfied": .bool(outcome.satisfied),
                    "value": outcome.value ?? .null,
                    "evaluations": JSONValue(outcome.evaluations),
                    "elapsed_ms": JSONValue((ContinuousClock.now - started).wholeMilliseconds),
                ]
                if !outcome.satisfied, let pointer = call.params["pointer"] { reply["pending"] = .array([pointer]) }
                return .object(reply)
            }.withLimit { request, _ in
                (try? OracleWaitCondition(params: request.params)).map { $0.limit + Self.replyMargin }
            },
        ]
    }

    /// `settleMaxMs` (an integer from 1 to ``maxSettleMilliseconds``; ``defaultSettleMilliseconds`` when absent).
    static func settleBound(_ params: [String: JSONValue]) throws(ControlError) -> Duration {
        guard let param = params["settleMaxMs"], !param.isNull else { return .milliseconds(defaultSettleMilliseconds) }
        guard let milliseconds = param.intValue, (1...maxSettleMilliseconds).contains(milliseconds) else {
            throw ControlError.invalidParams("settleMaxMs must be an integer from 1 to \(maxSettleMilliseconds)",
                                             data: ["param": "settleMaxMs"])
        }
        return .milliseconds(milliseconds)
    }

    struct WaitOutcome: Sendable {
        var satisfied: Bool
        /// The value at the pointer at the last read (nil: the pointer resolves to nothing).
        var value: JSONValue?
        var evaluations: Int
    }

    /// Reads `condition`'s facet until the condition holds or `deadline` passes. A read signals the next one on:
    /// a change to anything a main-actor provider read (each read runs inside Observation tracking), each change
    /// the provider's own ``OracleFacetProvider/changes`` stream reports (subscribed before the first read, so no
    /// change between the two is lost), and each control snapshot publish. No timer: the deadline is the
    /// snapshot store's own read-barrier deadline, which ends the publish wait and with it the signals. Off the
    /// main actor: only the facet read hops there.
    static func awaitCondition(_ condition: OracleWaitCondition, facets: OracleFacets, snapshots: ControlSnapshotStore,
                               deadline: ContinuousClock.Instant) async throws(ControlError) -> WaitOutcome {
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let from = snapshots.current.generation
        // task-owner: this wait; cancelled when it returns, and it ends itself at the deadline
        let publishes = Task { @concurrent in
            var seen = from
            while let published = await snapshots.snapshot(where: { [seen] in $0.generation > seen }, deadline: deadline) {
                seen = published.generation
                signal.yield()
            }
            signal.finish()
        }
        defer { publishes.cancel() }
        let providerChanges = facets.changes(condition.facet)?()
        let forwarding = providerChanges.map { changes in
            // task-owner: this wait; cancelled when it returns, which ends the provider's subscription
            Task { @concurrent in
                for await _ in changes { signal.yield() }
            }
        }
        defer { forwarding?.cancel() }
        var outcome = WaitOutcome(satisfied: false, value: nil, evaluations: 0)
        func evaluate() async throws(ControlError) -> Bool {
            let value = try await read(condition, facets: facets) { signal.yield() }
            outcome.evaluations += 1
            outcome.value = value
            outcome.satisfied = condition.holds(value)
            return outcome.satisfied
        }
        if try await evaluate() { return outcome }
        for await _ in signals {
            if ContinuousClock.now >= deadline { break }
            if try await evaluate() { break }
        }
        return outcome
    }

    /// The value at `condition`'s pointer now. The facet's main-actor read runs under Observation tracking:
    /// `changed` fires once when anything it read changes.
    @MainActor
    private static func read(_ condition: OracleWaitCondition, facets: OracleFacets,
                             changed: @escaping @Sendable () -> Void) async throws(ControlError) -> JSONValue? {
        // view-observation-allow: one tracking per read of a bounded debug wait, no view; ServiceObservation does not exist yet
        let begun: Result<OracleCapture, OracleSnapshotError> = withObservationTracking {
            do throws(OracleSnapshotError) {
                return .success(try facets.beginCapture([condition.facet]))
            } catch {
                return .failure(error)
            }
        } onChange: {
            changed()
        }
        let snapshot: OracleValue
        do throws(OracleSnapshotError) {
            let capture = try begun.get()
            if let completed = capture.completed {
                snapshot = completed
            } else {
                snapshot = try await capture.finish()
            }
        } catch {
            throw ControlError(code: "internal_error", message: error.message, data: ["facet": .string(error.facet.rawValue)])
        }
        guard let facetValue = snapshot[condition.facet.rawValue] else { return nil }
        return condition.value(in: OracleControl.json(facetValue))
    }
}
#endif
