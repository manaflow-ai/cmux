import CmuxNextServer
import Foundation
import Testing
@testable import CmuxNextApp

/// The consent state machine over every interleaving of its requests: reads, Mac Screen tickets, grants,
/// revokes and the sheet's Deny, started in each order and answered by acpmux in each order. Whatever
/// the order, a ticket serves only on the newest generation's explicit grant with no write in flight
/// (else it is refused), a stale grant never survives, a Deny never writes or closes the sheet over a
/// write, and one more read always brings the model to what acpmux holds.
@MainActor @Suite(.serialized) struct JoinConsentInterleavingTests {
    enum Op: String, CaseIterable {
        case read, ticket, grant, revoke, deny
        /// Takes a generation (the sheet's Deny does not: it only closes the sheet).
        var isRequest: Bool { self != .deny }
        var isWrite: Bool { self == .grant || self == .revoke }
    }

    /// One run: the model, a fake acpmux whose line is held at its first call per request until released.
    final class Run {
        let fake = JoinConsentTests.Fake()
        var holding = false
        var gates: [JoinConsentTests.Gate] = []
        var model: JoinConsentModel!

        init(granted: Bool) async {
            fake.record = JoinConsentRecord(screen: granted)
            let base = fake.services()
            model = JoinConsentModel(services: JoinConsentServices(
                status: base.status,
                openLine: { [self] in
                    if holding {
                        let gate = JoinConsentTests.Gate()
                        gates.append(gate)
                        await gate.wait()
                    }
                    return await base.openLine()
                },
                enabled: base.enabled, askShown: base.askShown, markAskShown: base.markAskShown))
            await model.refresh()
            model.refused(JoinConsentRefusal(requester: "Studio", surface: .screen))
        }
    }

    /// Every start order of `ops`, each with every answer order of the requests that waited on acpmux.
    @Test(arguments: [false, true])
    func everyOrderEndsOnTheNewestGenerationOrARefusal(granted: Bool) async {
        var runs = 0
        for ops in Self.combinations(of: Op.allCases, size: 2) + Self.combinations(of: Op.allCases, size: 3) {
            for starts in Self.permutations(ops) {
                // Which requests wait on acpmux depends only on the start order (a write in flight refuses at once).
                let probe = await Self.start(starts, granted: granted)
                for answers in Self.permutations(Array(probe.gated.indices)) {
                    await Self.check(starts, answers: answers, granted: granted)
                    runs += 1
                }
                for gate in probe.run.gates { gate.open() }
                for task in probe.tasks { _ = await task.value }
            }
        }
        #expect(runs > 300)
    }

    private struct Started {
        let run: Run
        var tasks: [Task<String, Never>] = []
        /// The index in the start order of each request that waits on its own gate, by gate.
        var gated: [Int] = []
        var writes = 0
        var writeInFlight = false
        var sheetKeptByDeny = false
        var newestRequest = -1
    }

    private static func start(_ starts: [Op], granted: Bool) async -> Started {
        let run = await Run(granted: granted)
        var started = Started(run: run)
        run.holding = true
        for (index, op) in starts.enumerated() {
            let before = run.gates.count
            let writingBefore = run.model.writing
            let task = Task { () -> String in
                switch op {
                case .read: await run.model.refresh(); return "read"
                case .ticket: return await run.model.allowsMacScreen(control: false, requester: "Studio") ? "served" : "refused"
                case .grant: return await run.model.set(.screen, on: true) ?? "set"
                case .revoke: return await run.model.set(.screen, on: false) ?? "set"
                case .deny: return await run.model.answer(allow: false) ?? "answered"
                }
            }
            started.tasks.append(task)
            // A request either waits on acpmux (a new gate) or answers at once.
            for _ in 0..<1000 where run.gates.count == before { await Task.yield() }
            if run.gates.count > before { started.gated.append(index) }
            if op.isRequest, !(op.isWrite && writingBefore), !(op == .ticket && writingBefore) { started.newestRequest = index }
            if op.isWrite, !writingBefore {
                started.writeInFlight = true
                if op == .revoke {
                    #expect(!run.model.permitsMacScreen(control: false), "a revoke narrows the moment it starts: \(starts)")
                }
            }
            if op == .deny, writingBefore { started.sheetKeptByDeny = true }
        }
        run.holding = false
        return started
    }

    private static func check(_ starts: [Op], answers: [Int], granted: Bool) async {
        let started = await start(starts, granted: granted)
        let run = started.run
        let label = "\(starts.map(\.rawValue)) answered \(answers.map { starts[started.gated[$0]].rawValue }), granted \(granted)"
        if started.sheetKeptByDeny { #expect(run.model.ask != nil, "a Deny never closes the sheet over a write: \(label)") }
        var results: [Int: String] = [:]
        for gate in answers {
            let index = started.gated[gate]
            let truth = run.fake.record.screen
            run.gates[gate].open()
            let result = await started.tasks[index].value
            results[index] = result
            if starts[index] == .ticket {
                // The newest generation's explicit grant, with no write ever in flight around it; else refused.
                let expected = index == started.newestRequest && !started.writeInFlight && truth
                #expect((result == "served") == expected, "ticket: \(label)")
            }
        }
        for task in started.tasks { _ = await task.value }
        // A ticket refused at once (a write in flight) never serves.
        for (index, op) in starts.enumerated() where op == .ticket && results[index] == nil {
            #expect(await started.tasks[index].value == "refused", "ticket during a write: \(label)")
        }
        // One write at a time: the first write sent; one started while it was in flight was refused as busy.
        // The sheet's Deny never writes.
        #expect(run.fake.writes.count == (started.writeInFlight ? 1 : 0), "writes: \(label)")
        // No stale grant survives, and one more read brings the model to what acpmux holds.
        #expect(!(run.model.permitsMacScreen(control: false) && !run.fake.record.screen), "stale grant: \(label)")
        await run.model.refresh()
        #expect(run.model.permitsMacScreen(control: false) == run.fake.record.screen, "converges: \(label)")
        #expect(!run.model.writing)
    }

    static func combinations<T>(of items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [[]] }
        guard let first = items.first else { return [] }
        let rest = Array(items.dropFirst())
        return combinations(of: rest, size: size - 1).map { [first] + $0 } + combinations(of: rest, size: size)
    }

    static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let item = rest.remove(at: index)
            return permutations(rest).map { [item] + $0 }
        }
    }
}
