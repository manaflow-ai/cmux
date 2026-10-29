#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextInvariants

/// A hand-set world the test rules read: the state a rule's `read` returns, so a test breaks and repairs an
/// invariant without an app.
@MainActor
final class InvariantTestWorld {
    /// The panes and how many tabs each shows and holds (the rule: they are equal).
    var strips: [String: Strip] = [:]
    /// Level precondition: a drag in flight (the rule does not apply).
    var dragInFlight = false
    /// The windows whose focus target is still pending, and since when.
    var pending: [String: ContinuousClock.Instant] = [:]
    /// Window w1 is in a live resize (rule G9 skips it), and its page is off its pane (G9's break).
    var resizing = false
    var pageOff = true
    var reads = 0

    struct Strip: Hashable, Codable, Sendable {
        var pane: String
        var shown: Int
        var held: Int
    }

    /// Rule T1, at `points`: every strip shows what its pane holds; it does not apply while a drag is in flight. It
    /// reads only the dirty panes after a turn (the scope of section 9's LG2 example).
    func stripRule(id: InvariantID = "T1", points: InvariantCheckPoints = [.afterAction, .afterTurn]) -> InvariantRule {
        InvariantRule(id: id, statement: "every strip shows exactly its pane's tabs", owner: "Tests", reads: [.tabs],
                      points: points, cost: .walk,
                      read: { [unowned self] (pass: InvariantPass) -> [Strip]? in
                          self.reads += 1
                          guard !self.dragInFlight else { return nil }
                          let panes = pass.dirty(.tabs).map { Set($0.compactMap(\.paneID)) }
                          return self.strips.values.filter { panes?.contains($0.pane) ?? true }.sorted { $0.pane < $1.pane }
                      },
                      check: { (strips: [Strip]) -> [InvariantFinding] in
                          strips.filter { $0.shown != $0.held }
                              .map { InvariantFinding(subject: .pane($0.pane), detail: "shows \($0.shown), holds \($0.held)") }
                      })
    }

    /// Rule G9: window w1's page covers its pane; a window in a live resize is skipped, not checked.
    func pageRule() -> InvariantRule {
        InvariantRule(id: "G9", statement: "a window's page covers it", owner: "Tests", reads: [.paneFrame],
                      points: .afterTurn, cost: .walk,
                      read: { [unowned self] (pass: InvariantPass) -> [String]? in
                          if self.resizing { pass.skip(.window("w1")) }
                          return self.resizing || !self.pageOff ? [] : ["w1"]
                      },
                      check: { $0.map { InvariantFinding(subject: .window($0), detail: "page off") } })
    }

    /// Liveness rule L1: a window's focus target lands within `limit`.
    func landsRule(limit: Duration) -> InvariantRule {
        .liveness(id: "L1", statement: "a focus target lands", owner: "Tests", reads: [.focus], limit: limit) { [unowned self] _ in
            self.pending.map { InvariantPending(subject: .window($0.key), since: $0.value, detail: "focus pending") }
        }
    }
}

extension InvariantSubject {
    var paneID: String? {
        if case .pane(let id) = self { return id }
        return nil
    }
}

/// A clock and a deadline a test moves by hand.
@MainActor
final class InvariantTestClock {
    var now = ContinuousClock.now
    var scheduled: (delay: Duration, work: @MainActor () -> Void)?

    func registry(mode: InvariantMode = .on) -> InvariantRegistry {
        InvariantRegistry(mode: mode, now: { [unowned self] in self.now }, schedule: { [unowned self] delay, work in
            self.scheduled = (delay, work)
        })
    }

    /// Moves the clock to the scheduled deadline and fires it.
    func fire() {
        guard let scheduled else { return }
        self.scheduled = nil
        now += scheduled.delay
        scheduled.work()
    }
}
#endif
