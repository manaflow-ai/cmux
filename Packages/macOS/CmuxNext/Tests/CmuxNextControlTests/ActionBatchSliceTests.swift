import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Every run in order, and how long each held the main thread.
private final class SliceLog: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// An action that holds the main thread `holding` per run (a New Column, a New Browser Tab).
private final class SlowExecutor: ControlActionExecutor {
    let log: SliceLog
    let holding: Duration

    init(log: SliceLog, holding: Duration) {
        self.log = log
        self.holding = holding
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        spin(for: holding)
        log.append("op")
        return .ran
    }
}

/// The app's frame source with its main-thread budget: frames fire by hand, each as one automation
/// batch (the app's control `FrameBatcher`); `scheduleSoon` (an idle queue's first request and every
/// injected key) hops through the main run loop.
private final class BudgetFrames: ControlFrameSource {
    private let frames = ManualFrameSource()
    // Read only on the main actor (mainFrameBudget, fire).
    nonisolated(unsafe) private let budgetRef: MainFrameBudget
    let mainTaskBoard: MainTaskBoard?
    private let tick = Mutex<Double>(0)

    @MainActor init(budget: MainFrameBudget) {
        budgetRef = budget
        mainTaskBoard = budget.board
    }

    @MainActor var mainFrameBudget: MainFrameBudget? { budgetRef }

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { frames.scheduleFrame(work) }

    func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) { MainRunLoopHop().perform(work) }

    @MainActor func fire() {
        let timestamp = tick.withLock { $0 += 1; return $0 }
        budgetRef.beginFrame(timestamp: timestamp, refreshInterval: 1.0 / 60)
        budgetRef.run(.automation, owner: "Control.frames") { frames.fire() }
    }
}

/// A long `action.batch` never stands between the person and the frame (CLAUDE.md "Go past Chrome
/// where cmux is scripted"): its ops run in slices that each fit the automation class's per-frame
/// budget, and a key pressed while it runs is handled before the batch ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ActionBatchSliceTests {
    @Test func aLongBatchRunsInBudgetedSlicesAndAKeyGoesBetweenThem() throws {
        let budget = MainFrameBudget()
        let frames = BudgetFrames(budget: budget)
        let log = SliceLog()
        let perOp = Duration.microseconds(400)
        let router = ControlRouter(identity: testIdentity(), executor: SlowExecutor(log: log, holding: perOp),
                                   configuration: .loadTolerant, frameSource: frames)
        router.snapshots.publish { $0.catalog = sampleCatalog() }
        let ops = (0..<64).map { index -> JSONValue in
            ["action": "selectWorkspaceByNumber", "args": ["index": JSONValue(index % 9 + 1)]]
        }
        let reply = Mutex<Result<JSONValue, ControlError>?>(nil)
        Task.detached {
            let result = await router.handle(ControlRequest(id: "1", method: "action.batch", params: ["ops": .array(ops)]))
            reply.withLock { $0 = result }
        }
        let end = ContinuousClock.now + .seconds(30)
        // The batch starts (an idle queue runs its first request on the next run loop turn).
        while log.all.isEmpty, ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        // The person presses a key while the batch runs.
        let deadline = ContinuousClock.now + .seconds(20)
        Task.detached {
            _ = try await router.workQueue.run(connection: ControlConnectionID(rawValue: 99), method: "debug.key", workClass: .input,
                                               deadline: deadline) { log.append("key") }
        }
        while reply.withLock({ $0 }) == nil, ContinuousClock.now < end {
            frames.fire()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        _ = try #require(reply.withLock { $0 }).get()
        let entries = log.all
        #expect(entries.filter { $0 == "op" }.count == 64)
        let key = try #require(entries.firstIndex(of: "key"), "the key never ran")
        #expect(key < entries.count - 1, "the key waited for the whole batch (\(entries.count - 1 - key) ops after it)")
        // One slice: the automation budget for a frame, plus the op that crossed it, plus scheduling slack.
        let slice = budget.budgets.automation + perOp + .milliseconds(1)
        #expect(router.workQueue.stats.maxFrameWork <= slice,
                "a slice held the main thread \(router.workQueue.stats.maxFrameWork), more than one automation slice (\(slice))")
    }
}
