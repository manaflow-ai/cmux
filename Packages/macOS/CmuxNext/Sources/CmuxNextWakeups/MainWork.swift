/// Main-actor tasks that are part of a person's input or of the frame: the
/// ``MainJobGate`` never holds their jobs, while it holds every other main-actor job behind
/// pending input.
///
/// A plain `Task {}` made on the main actor outside an input's dispatch waits for the input's
/// frame to commit while input is pending. Work that is the input's own answer (a key's echo the
/// dispatch could not finish) or frame-locked work (a spring step, a frame probe) goes through
/// ``input(_:)`` or ``frame(_:)``: the task's first job passes the gate, and so does every later
/// job of the same task, until its body returns. Tasks it makes are classified on their own.
///
/// Without a gate (feature `mainJobGate` off), both make a plain task.
///
/// ```swift
/// let work = MainWork(gate: jobGate)
/// work.input { await editor.applyPendingKey() }
/// ```
public struct MainWork: Sendable {
    private let gate: MainJobGate?

    /// - Parameter gate: The installed gate, or nil.
    public init(gate: MainJobGate?) {
        self.gate = gate
    }

    /// Runs `body` on the main actor as input work: the gate passes its jobs.
    @MainActor @discardableResult
    public func input(_ body: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        task(.input, body)
    }

    /// Runs `body` on the main actor as frame work: the gate passes its jobs.
    @MainActor @discardableResult
    public func frame(_ body: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        task(.frame, body)
    }

    @MainActor
    private func task(_ stamp: MainJobGate.Stamp, _ body: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        guard let gate else {
            // main-hop-allow: the input or frame class's own hop (MainWork is the classed API the gate exempts)
            return Task { @MainActor in await body() }
        }
        return gate.stamping(stamp) {
            // main-hop-allow: the input or frame class's own hop (MainWork is the classed API the gate exempts)
            Task { @MainActor in
                let job = MainWork.currentJob()
                if let job { gate.stamp(job, stamp) }
                defer { if let job { gate.unstamp(job) } }
                await body()
            }
        }
    }

    /// The running task as the hook sees its jobs (a task's job is the task).
    static func currentJob() -> UInt? {
        withUnsafeCurrentTask { task in
            // SAFETY: UnsafeCurrentTask holds one reference, the running AsyncTask, and an AsyncTask is
            // the Job the enqueue hook gets as its UnownedJob, at the same address. unsafeBitCast traps if
            // the sizes ever differ; the address is compared, never dereferenced or retained.
            task.map { unsafe unsafeBitCast($0, to: UInt.self) }
        }
    }
}
