#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

extension InvariantRegistry {
    // perf-hot: 1ms invariants-turn
    /// The end of a committed main turn (``InvariantTurnObserver``, after the Core Animation commit): runs every rule
    /// due, on every turn, with no cap and no carry-over (section 3). Due: the `.afterAction` rules when an action ran
    /// this turn, the `.afterTurn` rules that read a key this turn touched, and the liveness rules once their
    /// deadline came. An idle turn (nothing ran, nothing touched) is one test and returns.
    public func runTurn() {
        guard mode.isArmed, !turnActions.isEmpty || !touched.isEmpty || livenessDue else { return }
        let start = now()
        turn += 1
        let keys = touched
        touched = [:]
        let actions = turnActions
        turnActions = []
        let deadlineCame = livenessDue
        livenessDue = false
        let kind: InvariantTrigger.Kind = !actions.isEmpty ? .action : keys.isEmpty ? .liveness : .turn
        // An action may change any state: after one, every subject counts as dirty.
        let pass = InvariantPass(trigger: InvariantTrigger(kind: kind, actions: actions, turn: turn), touched: keys,
                                 isFull: !actions.isEmpty, now: start, clock: now)
        var due = Set<Int>()
        if !actions.isEmpty { due.formUnion(afterActionRules) }
        for key in keys.keys {
            if let indices = byKey[key] { due.formUnion(indices) }
        }
        if deadlineCame { due.formUnion(livenessRules) }
        for index in due.sorted() { run(index, in: pass) }
        turnsChecked += 1
        armLivenessDeadline()
        passTiming.record(now() - start)
    }

    /// Runs every rule now that is not a harness rule (or only `ids`), on every subject: `debug.invariants
    /// {check: true}` and tests. New signatures are reported as a turn would; the result is every current finding.
    @discardableResult
    public func checkNow(ids: Set<InvariantID>? = nil) -> [(id: InvariantID, finding: InvariantFinding)] {
        let pass = fullPass()
        var current: [(id: InvariantID, finding: InvariantFinding)] = []
        for index in rules.indices where ids?.contains(rules[index].id) ?? true {
            let id = rules[index].id
            current += run(index, in: pass).map { (id: id, finding: $0) }
        }
        armLivenessDeadline()
        return current
    }

    /// Runs the harness rules (or only `ids`): `debug.invariants {check: true, ipc: true}`. Their reads may await
    /// another process; the main thread is never blocked meanwhile.
    public func checkHarness(ids: Set<InvariantID>? = nil) async -> [(id: InvariantID, finding: InvariantFinding)] {
        let pass = fullPass()
        var current: [(id: InvariantID, finding: InvariantFinding)] = []
        for index in rules.indices where ids?.contains(rules[index].id) ?? true {
            guard case .harness(let evaluate) = rules[index].body else { continue }
            let start = now()
            guard let evaluation = await evaluate(pass) else { continue }
            records[index].timing.record(now() - start)
            records[index].checks += 1
            settle(index, evaluation.findings, state: evaluation.state, trigger: pass.trigger)
            let id = rules[index].id
            current += evaluation.findings.map { (id: id, finding: $0) }
        }
        return current
    }

    /// Each parity rule's read state now, as canonical JSON (`debug.invariants {state: true}`, the R4 diff).
    public func paritySnapshot() -> [InvariantID: Data] {
        let pass = fullPass()
        var snapshot: [InvariantID: Data] = [:]
        for rule in rules where rule.parity {
            guard case .state(let evaluate) = rule.body, let data = evaluate(pass)?.state() else { continue }
            snapshot[rule.id] = data
        }
        return snapshot
    }

    private func fullPass() -> InvariantPass {
        turn += 1
        return InvariantPass(trigger: InvariantTrigger(kind: .check, actions: recentActions, turn: turn), touched: [:],
                             isFull: true, now: now(), clock: now)
    }

    /// Runs rule `index` in `pass`: times it (without the memo builds it did for the pass), reports each signature
    /// that is new since its last run found it clear, and returns every current finding (none when it did not
    /// apply).
    @discardableResult
    func run(_ index: Int, in pass: InvariantPass) -> [InvariantFinding] {
        let start = now()
        let memoBefore = pass.memoTime
        var findings: [InvariantFinding]?
        var state: (() -> Data?)?
        switch rules[index].body {
        case .state(let evaluate):
            let evaluation = evaluate(pass)
            findings = evaluation?.findings
            state = evaluation?.state
        case .liveness(let limit, let pending):
            findings = overdue(index, limit: limit, pending(pass), at: pass.now)
        case .harness:
            return []
        }
        records[index].timing.record(now() - start - (pass.memoTime - memoBefore))
        records[index].checks += 1
        judgeCost(index, trigger: pass.trigger)
        guard let findings else { return [] }
        settle(index, findings, state: state, trigger: pass.trigger)
        return findings
    }

    /// Reports the findings of rule `index` whose signature is new since the rule last found it clear; a rule that
    /// confirms at its next check reports a signature only when two runs in a row find it.
    func settle(_ index: Int, _ findings: [InvariantFinding], state: (() -> Data?)?, trigger: InvariantTrigger) {
        guard !findings.isEmpty else {
            records[index].reported = []
            records[index].suspected = []
            return
        }
        let rule = rules[index]
        let prefix = "\(rule.id.rawValue)@\(host)@"
        let signatures = findings.map { prefix + $0.subject.description }
        let current = Set(signatures)
        var record = records[index]
        record.reported.formIntersection(current)
        let fresh: Set<String>
        if rule.confirmsAtNextCheck {
            fresh = current.intersection(record.suspected).subtracting(record.reported)
            record.suspected = current.subtracting(record.reported).subtracting(fresh)
        } else {
            fresh = current.subtracting(record.reported)
        }
        record.reported.formUnion(fresh)
        record.violations += UInt64(fresh.count)
        records[index] = record
        guard !fresh.isEmpty else { return }
        let encoded = state?()
        var sent: Set<String> = []
        for (finding, signature) in zip(findings, signatures) {
            guard fresh.contains(signature), sent.insert(signature).inserted else { continue }
            report(id: rule.id, subject: finding.subject, detail: finding.detail, state: encoded, trigger: trigger)
        }
    }

    /// A liveness rule's findings: each pending subject that has waited `limit` or longer. Keeps each subject's start
    /// and the earliest limit still ahead, which ``armLivenessDeadline()`` waits for.
    func overdue(_ index: Int, limit: Duration, _ pending: [InvariantPending],
                 at time: ContinuousClock.Instant) -> [InvariantFinding] {
        var seen: [InvariantSubject: ContinuousClock.Instant] = [:]
        var next: ContinuousClock.Instant?
        var findings: [InvariantFinding] = []
        for item in pending {
            let since = item.since ?? records[index].firstSeen[item.subject] ?? time
            seen[item.subject] = since
            let waited = time - since
            if waited >= limit {
                findings.append(InvariantFinding(subject: item.subject, detail: "\(item.detail); pending "
                    + "\(Self.milliseconds(waited)) ms, limit \(Self.milliseconds(limit)) ms"))
            } else {
                next = min(next ?? since + limit, since + limit)
            }
        }
        records[index].firstSeen = seen
        records[index].nextDue = next
        return findings
    }

    /// Asks for one pass at the earliest liveness limit still ahead, so a wait that ends nowhere is reported with no
    /// input to run a check. The deadline only marks the liveness rules due; the turn it fires in runs them.
    func armLivenessDeadline() {
        guard mode.isArmed, let earliest = livenessRules.compactMap({ records[$0].nextDue }).min(),
              livenessDeadline.map({ earliest < $0 }) ?? true else { return }
        livenessDeadline = earliest
        schedule(max(.zero, earliest - now())) { [weak self] in
            guard let self else { return }
            livenessDeadline = nil
            livenessDue = true
        }
    }

    /// A rule whose p95 run time is above ``costLimitMicros`` is reported once as `INV-COST@<id>` until it is back
    /// under it (section 4).
    func judgeCost(_ index: Int, trigger: InvariantTrigger) {
        let record = records[index]
        guard record.checks >= Self.costMinimumRuns else { return }
        let p95 = record.timing.percentile(0.95)
        guard p95 > Self.costLimitMicros else {
            costReported.remove(index)
            return
        }
        guard costReported.insert(index).inserted else { return }
        let id = rules[index].id
        report(id: InvariantID(rawValue: "INV-COST@\(id.rawValue)"), subject: .app,
               detail: "\(id.rawValue) runs \(Int(p95)) µs at p95 over \(record.checks) runs, above "
                   + "\(Int(Self.costLimitMicros)) µs: make its scope smaller", state: nil, trigger: trigger)
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
#endif
