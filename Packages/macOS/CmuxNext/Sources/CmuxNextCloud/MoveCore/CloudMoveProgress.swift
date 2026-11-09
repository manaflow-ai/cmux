public import Foundation
import CmuxNextWakeups

/// Move to Cloud's and Bring Back Local's working toast while the chat moves: the step it is on, why it
/// waits there and about how long is left, as Rust says it (`moves::progress`, op `cloud_move_progress`).
/// Glue only: the app says which step runs and pushes the folder copy's progress lines as they come;
/// Rust answers the line and when it next changes on its own (`nextMs`). The one timer here is a
/// one-shot ``DemandTimer`` at that moment, replaced by every new answer. It stops when the move ends (``end()``,
/// which the app's run calls on success, failure and cancellation alike) and never outlives this
/// object (it holds it weakly).
@MainActor
public final class CloudMoveProgress {
    public enum Direction: String, Encodable, Sendable { case move, bringBack }
    public enum Stage: String, Encodable, Sendable { case machine, copy, agent, tab }

    /// What the app tells Rust (op `cloud_move_progress`).
    struct Facts: Encodable, Equatable {
        var direction: Direction, stage: Stage, machine: String?, name: String?, stageMs: UInt64, copy: SeedProgress?
    }
    /// Rust's answer: the line, and how long until it changes on its own.
    struct Line: Decodable, Equatable { var text: String, nextMs: UInt64? }

    private let direction: Direction
    private let show: @MainActor (String) -> Void
    private let elapsed: @Sendable () -> Duration
    private let ask: @MainActor (Facts) -> Line?
    private var facts: (stage: Stage, machine: String?, name: String?)?
    private var started = Duration.zero
    private var copy: SeedProgress?
    private var shown: String?
    private let wake: DemandTimer

    /// `show` gets each new line (the app puts it under the toast's headline).
    public convenience init(_ direction: Direction, show: @escaping @MainActor (String) -> Void) {
        self.init(direction, clock: ContinuousClock(), show: show)
    }

    /// ``init(_:show:)`` on `clock` (a test's manual clock).
    public convenience init<C: Clock & Sendable>(_ direction: Direction, clock: C, show: @escaping @MainActor (String) -> Void)
        where C.Duration == Duration {
        self.init(direction, clock: clock, ask: { CloudMoveCore().call("progress", $0, as: Line.self) }, show: show)
    }

    /// ``init(_:clock:show:)`` asking `ask` in place of Rust (a test's answers).
    init<C: Clock & Sendable>(_ direction: Direction, clock: C, ask: @escaping @MainActor (Facts) -> Line?,
                              show: @escaping @MainActor (String) -> Void) where C.Duration == Duration {
        self.direction = direction
        self.show = show
        self.ask = ask
        let origin = clock.now
        elapsed = { origin.duration(to: clock.now) }
        wake = DemandTimer(owner: "CloudMoveProgress", clock: clock)
    }

    /// Whether a wake is set: only while a move runs and its line changes on its own.
    public var isWaiting: Bool { wake.isScheduled }

    /// The move starts `stage` now; `machine` is the machine's status as Cloud says it (`new`: none yet), `name` its
    /// name, once there is one. Rust reads what they mean.
    public func enter(_ stage: Stage, machine: String? = nil, name: String? = nil) {
        facts = (stage, machine, name)
        started = elapsed()
        copy = nil
        render()
    }

    /// The move reaches `machine` now; nil: Cloud starts a new one.
    public func reaching(_ machine: CloudMachine?) {
        enter(.machine, machine: machine?.status.rawValue ?? "new", name: machine?.title)
    }

    /// The folder copy's newest progress line, pushed as it comes.
    public func copied(_ progress: SeedProgress) {
        copy = progress
        render()
    }

    /// Something else shows on the toast for now (a machine update): no line until the next ``enter(_:machine:name:)``.
    public func hold() {
        (facts, shown) = (nil, nil)
        stopWaking()
    }

    /// The move ended: no more lines and no wake.
    public func end() {
        facts = nil
        stopWaking()
    }

    private func stopWaking() { wake.cancel() }

    private func render() {
        stopWaking()
        guard let facts else { return }
        let ms = UInt64(max(0, (elapsed() - started).wholeMilliseconds))
        let request = Facts(direction: direction, stage: facts.stage, machine: facts.machine, name: facts.name, stageMs: ms, copy: copy)
        guard let line = ask(request) else { return }
        if line.text != shown {
            shown = line.text
            show(line.text)
        }
        guard let next = line.nextMs else { return }
        // One deadline when Rust says the line next changes; each answer replaces it, end() and hold() cancel it.
        wake.schedule(after: .milliseconds(Int64(clamping: next))) { @MainActor [weak self] in self?.render() }
    }
}
