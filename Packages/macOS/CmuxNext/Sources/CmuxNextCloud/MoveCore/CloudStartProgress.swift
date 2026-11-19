import CmuxNextCompat
public import Foundation
import CmuxNextWakeups

/// Setup progress returned with a Cloud start plan and forwarded to the startup card (Rust reads it
/// from the plan's answer, `moves::cli::Setup`).
public struct CloudStartSetup: Sendable, Equatable, Decodable {
    public var state: String?
    public var status: String?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var error: String?
    public var hasScript: Bool?
}

/// The environment and setup state carried by a `link start-chat plan` answer.
public struct CloudStartInfo: Sendable, Equatable {
    public var environmentId: String?
    public var setup: CloudStartSetup?

    public init(environmentId: String? = nil, setup: CloudStartSetup? = nil) {
        self.environmentId = environmentId
        self.setup = setup
    }
}

/// One progress line of `cmux link seed push` (stderr, `{"progress":{...}}`; cmux-tui `link/seed_cli.rs`), as
/// numbers for the start card's clone row. Rust reads the lines and says which to hand on (`moves::seed`).
public nonisolated struct SeedProgress: Sendable, Equatable, Codable {
    /// `upload`, `clone`, `fetch`, `bundle`, `checkout`, `submodules`, `lfs`, or `copy` for the streamed copy.
    public var phase: String
    public var bytesDone: Int?
    public var bytesTotal: Int?
    public var objects: Int?
    public var objectsTotal: Int?
    public var filesDone: Int?
    public var filesTotal: Int?
    /// A seed that copied instead: why, and the cmux GitHub App's install link for `seed.needs_github`.
    public var fallbackCode: String?
    public var installURL: String?

    public init(phase: String, bytesDone: Int? = nil, bytesTotal: Int? = nil, objects: Int? = nil, objectsTotal: Int? = nil,
                filesDone: Int? = nil, filesTotal: Int? = nil, fallbackCode: String? = nil, installURL: String? = nil) {
        (self.phase, self.bytesDone, self.bytesTotal, self.objects, self.objectsTotal) = (phase, bytesDone, bytesTotal, objects, objectsTotal)
        (self.filesDone, self.filesTotal, self.fallbackCode, self.installURL) = (filesDone, filesTotal, fallbackCode, installURL)
    }

    /// The reader's memory between lines (Rust's `seed::Reader`), kept here as JSON.
    private struct Reader: Codable, Sendable {
        var lastMs: Double?, phase: String?, fallbackCode: String?, installURL: String?
    }

    private struct Read: Decodable { var progress: SeedProgress?; var reader: Reader? }

    /// The line's progress; nil for any other line.
    public static func parse(_ line: String) -> SeedProgress? {
        struct Request: Encodable { var line: String }
        return CloudMoveCore().call("seed_read", Request(line: line), as: Read.self)?.progress
    }

    /// A stderr line reader that hands `handle` each progress line Rust says to: at most about 4 a second, except a
    /// phase change, which always goes; a fallback's code and install link stay on the copy's lines after it.
    public static func reader(_ handle: @escaping @Sendable (SeedProgress) -> Void) -> @Sendable (String) -> Void {
        struct Request: Encodable { var reader: Reader, line: String, nowMs: Double }
        let start = ContinuousClock.now
        let state = Mutex(Reader())
        return { line in
            guard line.hasPrefix("{") else { return }
            let elapsed = start.duration(to: .now).components
            let now = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            let progress = state.withLock { reader -> SeedProgress? in
                guard let read = CloudMoveCore().call("seed_read", Request(reader: reader, line: line, nowMs: now), as: Read.self) else { return nil }
                if let next = read.reader { reader = next }
                return read.progress
            }
            if let progress { handle(progress) }
        }
    }

    /// Runs `run` with a stderr line reader (``reader(_:)``) and hands each progress value to `each` on the main
    /// actor while it runs; returns `run`'s answer once both are done. The stream keeps only the newest value.
    @MainActor
    public static func feed<Answer: Sendable>(_ run: @escaping @Sendable (_ stderrLine: @escaping @Sendable (String) -> Void) async throws -> Answer,
                                              each: (SeedProgress) -> Void) async throws -> Answer {
        let (values, sink) = AsyncStream.makeStream(of: SeedProgress.self, bufferingPolicy: .bufferingNewest(1))
        async let answer = Self.running(run, into: sink)
        for await value in values { each(value) }
        return try await answer
    }

    private static func running<Answer: Sendable>(_ run: @Sendable (_ stderrLine: @escaping @Sendable (String) -> Void) async throws -> Answer,
                                                  into sink: AsyncStream<SeedProgress>.Continuation) async throws -> Answer {
        defer { sink.finish() }
        return try await run(reader { sink.yield($0) })
    }
}

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
        /// How long the step had run when `copy` came: Rust counts its estimate down from then, and says when it is stale.
        var copyMs: UInt64?
    }
    /// Rust's answer: the line, and how long until it changes on its own.
    struct Line: Decodable, Equatable {
        var text: String, nextMs: UInt64?
        /// How far the whole move is, 0...1 (the sidebar's moving row); nil from a Rust before it said.
        var fraction: Double?
    }

    /// Each new line with how far the whole move is (``ChatMoves``: the sidebar's moving chat row).
    public var stepped: (@MainActor (_ line: String, _ fraction: Double?) -> Void)?
    /// Called once the run ends (``end()``), done or not.
    public var ended: (@MainActor () -> Void)?

    private let direction: Direction
    private let show: @MainActor (String) -> Void
    private let elapsed: @Sendable () -> Duration
    private let ask: @MainActor (Facts) -> Line?
    private var facts: (stage: Stage, machine: String?, name: String?)?
    private var started = Duration.zero
    private var copy: SeedProgress?
    private var copyAt = Duration.zero
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
        copyAt = elapsed()
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
        ended?()
    }

    private func stopWaking() { wake.cancel() }

    private func render() {
        stopWaking()
        guard let facts else { return }
        let ms = UInt64(max(0, (elapsed() - started).wholeMilliseconds))
        let copyMs = copy.map { _ in UInt64(max(0, (copyAt - started).wholeMilliseconds)) }
        let request = Facts(direction: direction, stage: facts.stage, machine: facts.machine, name: facts.name, stageMs: ms, copy: copy, copyMs: copyMs)
        guard let line = ask(request) else { return }
        if line.text != shown {
            shown = line.text
            show(line.text)
            stepped?(line.text, line.fraction)
        }
        guard let next = line.nextMs else { return }
        // One deadline when Rust says the line next changes; each answer replaces it, end() and hold() cancel it.
        wake.schedule(after: .milliseconds(Int64(clamping: next))) { @MainActor [weak self] in self?.render() }
    }
}
