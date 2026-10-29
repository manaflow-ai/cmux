#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

extension InvariantRegistry {
    // perf-hot: 1ms invariants-turn
    /// The end of a committed main turn (``InvariantTurnObserver``, after the Core Animation commit): runs every rule
    /// due, on every turn, with no cap and no carry-over (section 3). Due: the `.afterAction` rules when an action ran
    /// this turn, the `.afterTurn` rules that read a key this turn touched, and the liveness rules once their
    /// deadline came. An idle turn (nothing ran, nothing touched) is one test and returns. The pass's own time, memo
    /// builds included, is judged against ``passLimitMicros`` (`INV-COST@pass`).
    public func runTurn() {
        guard mode.isArmed, !turnActions.isEmpty || !touched.isEmpty || livenessDue else { return }
        let start = now()
        turn += 1
        let keys = touched
        touched = [:]
        let actions = turnActions.ordered
        turnActions.removeAll()
        let deadlineCame = livenessDue
        livenessDue = false
        let kind: InvariantTrigger.Kind = !actions.isEmpty ? .action : keys.isEmpty ? .liveness : .turn
        // An action may change any state: after one, every subject counts as dirty. At a liveness limit too: the
        // liveness rules look again at every subject they wait on, touched or not.
        let pass = InvariantPass(trigger: InvariantTrigger(kind: kind, actions: actions, turn: turn), touched: keys,
                                 isFull: !actions.isEmpty || deadlineCame, now: start, clock: now)
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
        judgePassCost(trigger: pass.trigger)
        flushReports()
    }

    /// Runs every rule now that is not a harness-body rule (or only `ids`), on every subject: `debug.invariants
    /// {check: true}` after each journey step, and tests. A rule whose points are only `.harness` (an async peer with
    /// no in-flight ledger yet) runs here and never in a turn. New signatures are reported as a turn would; the result
    /// is every current finding.
    @discardableResult
    public func checkNow(ids: Set<InvariantID>? = nil) -> [(id: InvariantID, finding: InvariantFinding)] {
        let pass = fullPass()
        var current: [(id: InvariantID, finding: InvariantFinding)] = []
        for index in rules.indices where ids?.contains(rules[index].id) ?? true {
            let id = rules[index].id
            current += run(index, in: pass).map { (id: id, finding: $0) }
        }
        armLivenessDeadline()
        flushReports()
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
            settle(index, evaluation.findings, covered: .everything, state: evaluation.state, trigger: pass.trigger)
            let id = rules[index].id
            current += evaluation.findings.map { (id: id, finding: $0) }
        }
        flushReports()
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
        return InvariantPass(trigger: InvariantTrigger(kind: .check, actions: recentActions.ordered, turn: turn),
                             touched: [:], isFull: true, now: now(), clock: now)
    }

    /// Runs rule `index` in `pass`: times it (without the memo builds it did for the pass), reports each signature
    /// that is new since a run that checked its subject last found it clear, and returns every current finding (none
    /// when it did not apply).
    @discardableResult
    func run(_ index: Int, in pass: InvariantPass) -> [InvariantFinding] {
        let start = now()
        let memoBefore = pass.memoTime
        var findings: [InvariantFinding]?
        var state: (@Sendable () -> Data?)?
        pass.beginRule()
        switch rules[index].body {
        case .state(let evaluate):
            let evaluation = evaluate(pass)
            findings = evaluation?.findings
            state = evaluation?.state
        case .liveness(let limit, let pending):
            let waiting = pending(pass)
            findings = overdue(index, limit: limit, waiting, covered: pass.coverage(), at: pass.now)
        case .harness:
            return []
        }
        let covered = pass.coverage()
        records[index].timing.record(now() - start - (pass.memoTime - memoBefore))
        records[index].checks += 1
        judgeCost(index, trigger: pass.trigger)
        // A read that returned nil does not apply now (a level precondition): it clears nothing.
        guard let findings else { return [] }
        settle(index, findings, covered: covered, state: state, trigger: pass.trigger)
        return findings
    }

    /// Reports the findings of rule `index` whose signature is new: not reported, or reported and since found clear
    /// by a run that checked its subject. A signature whose subject this run did not check (another dirty subject's
    /// turn, a skipped window) stays as it was: reported stays reported, so a turn that touches p2 never re-arms a
    /// report of p1.
    func settle(_ index: Int, _ findings: [InvariantFinding], covered: InvariantCoverage,
                state: (@Sendable () -> Data?)?, trigger: InvariantTrigger) {
        let current = Set(findings.map(\.subject))
        var record = records[index]
        record.reported = record.reported.filter { current.contains($0) || !covered.covers($0) }
        let fresh = current.subtracting(record.reported)
        record.reported.formUnion(fresh)
        record.violations += UInt64(fresh.count)
        records[index] = record
        guard !fresh.isEmpty else { return }
        let id = rules[index].id
        var sent: Set<InvariantSubject> = []
        for finding in findings where fresh.contains(finding.subject) && sent.insert(finding.subject).inserted {
            report(id: id, subject: finding.subject, detail: finding.detail, state: state, trigger: trigger)
        }
    }

    /// A liveness rule's findings: each pending subject that has waited `limit` or longer. Keeps each subject's start
    /// and the earliest limit still ahead, which ``armLivenessDeadline()`` waits for. A subject this run did not check
    /// keeps its start (and its limit stays armed): only a run that looked at it can end its wait.
    func overdue(_ index: Int, limit: Duration, _ pending: [InvariantPending], covered: InvariantCoverage,
                 at time: ContinuousClock.Instant) -> [InvariantFinding] {
        var seen = records[index].firstSeen.filter { !covered.covers($0.key) }
        // A wait already past its limit was judged at that limit's full pass; only the limits still ahead are armed.
        var next = seen.values.map { $0 + limit }.filter { $0 > time }.min()
        var findings: [InvariantFinding] = []
        for item in pending where covered.covers(item.subject) {
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
        guard mode.isArmed, let earliest = livenessRules.compactMap({ records[$0].nextDue }).min() else { return }
        // A deadline still ahead and no later than this one serves it (it runs a full liveness pass, which arms the
        // next); one in the past is spent.
        let time = now()
        if let armed = livenessDeadline, armed > time, armed <= earliest { return }
        livenessDeadline = earliest
        schedule(max(.zero, earliest - time)) { [weak self] in
            guard let self else { return }
            livenessDeadline = nil
            livenessDue = true
        }
    }

    /// A rule whose p95 run time is above ``costLimitMicros`` is reported once as `INV-COST@<id>` until it is back
    /// under it (section 4). One comparison per run.
    func judgeCost(_ index: Int, trigger: InvariantTrigger) {
        let timing = records[index].timing
        guard timing.count >= Self.costMinimumRuns else { return }
        guard timing.isOverLimit(at: 0.95) else {
            costReported.remove(index)
            return
        }
        guard costReported.insert(index).inserted else { return }
        let id = rules[index].id
        report(id: InvariantID(rawValue: "INV-COST@\(id.rawValue)"), subject: .app,
               detail: "\(id.rawValue) runs \(Int(timing.percentile(0.95))) µs at p95 over \(timing.count) runs, above "
                   + "\(Int(Self.costLimitMicros)) µs: make its scope smaller", state: nil, trigger: trigger)
    }

    /// The pass's p95, memo builds included, above ``passLimitMicros`` is reported once as `INV-COST@pass` until it
    /// is back under it: the shared walk (one `InputObservation`) is charged to no rule, so only this sees it.
    func judgePassCost(trigger: InvariantTrigger) {
        guard passTiming.count >= Self.costMinimumRuns else { return }
        guard passTiming.isOverLimit(at: 0.95) else {
            passCostReported = false
            return
        }
        guard !passCostReported else { return }
        passCostReported = true
        report(id: "INV-COST@pass", subject: .app,
               detail: "a pass runs \(Int(passTiming.percentile(0.95))) µs at p95 over \(passTiming.count) passes, above "
                   + "\(Int(Self.passLimitMicros)) µs: make the shared reads (memos) or the rules' scopes smaller",
               state: nil, trigger: trigger)
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
#endif
