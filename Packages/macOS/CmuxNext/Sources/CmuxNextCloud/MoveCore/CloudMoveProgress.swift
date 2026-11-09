public import Foundation

/// Move to Cloud's and Bring Back Local's working toast while the chat moves: the step it is on, why it
/// waits there and about how long is left, as Rust says it (`moves::progress`, op `cloud_move_progress`).
/// The app says which step runs and hands on the folder copy's progress; this asks Rust again each
/// second for the countdown and hands `show` the line only when its text changed.
@MainActor
public final class CloudMoveProgress {
    public enum Direction: String, Encodable, Sendable { case move, bringBack }
    public enum Stage: String, Encodable, Sendable { case machine, copy, agent, tab }
    /// The machine the move reaches: running, paused (it resumes first) or none yet (Cloud starts one).
    public enum Machine: String, Encodable, Sendable { case live, paused, new }

    private struct Facts: Encodable {
        var direction: Direction, stage: Stage, machine: Machine, name: String?, stageMs: UInt64, copy: SeedProgress?
    }
    private struct Line: Decodable { var text: String }

    private let direction: Direction
    private let show: @MainActor (String) -> Void
    private var facts: (stage: Stage, machine: Machine, name: String?)?
    private var started = ContinuousClock.now
    private var copy: SeedProgress?
    private var shown: String?
    private var ticker: Task<Void, Never>?

    /// `show` gets each new line (the app puts it under the toast's headline).
    public init(_ direction: Direction, show: @escaping @MainActor (String) -> Void) {
        self.direction = direction
        self.show = show
    }

    /// The move starts `stage` now; `name` is the machine's, once there is one.
    public func enter(_ stage: Stage, machine: Machine = .live, name: String? = nil) {
        facts = (stage, machine, name)
        started = .now
        copy = nil
        render()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            // wakeup-allow: the countdown's one tick a second while a move runs; end() cancels it
            while !Task.isCancelled, (try? await Task.sleep(for: .seconds(1))) != nil {
                self?.render()
            }
        }
    }

    /// The move reaches `machine` now: resuming it when paused, connecting otherwise; nil: Cloud starts a new one.
    public func reaching(_ machine: CloudMachine?) {
        guard let machine else { return enter(.machine, machine: .new) }
        enter(.machine, machine: machine.status == .paused ? .paused : .live, name: machine.title)
    }

    /// The folder copy's newest progress line.
    public func copied(_ progress: SeedProgress) {
        copy = progress
        render()
    }

    /// Something else shows on the toast for now (a machine update): no line until the next ``enter(_:machine:name:)``.
    public func hold() { (facts, shown) = (nil, nil) }

    /// The move ended: no more lines.
    public func end() {
        ticker?.cancel()
        ticker = nil
        facts = nil
    }

    private func render() {
        guard let facts else { return }
        let ms = UInt64(max(0, started.duration(to: .now).wholeMilliseconds))
        let request = Facts(direction: direction, stage: facts.stage, machine: facts.machine, name: facts.name, stageMs: ms, copy: copy)
        guard let line = CloudMoveCore().call("progress", request, as: Line.self), line.text != shown else { return }
        shown = line.text
        show(line.text)
    }
}
