import CmuxNextCompat
import Foundation

/// One progress line of `cmux link seed push` (stderr, `{"progress":{...}}`; cmux-tui
/// `link/seed_cli.rs`), as numbers for the start card's clone row. The CLI and the page own the
/// words; this only forwards fields.
public nonisolated struct SeedProgress: Sendable, Equatable {
    /// `upload`, `clone`, `fetch`, `bundle`, `checkout`, `submodules`, `lfs`, or `copy` for the
    /// streamed copy (its lines carry files).
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

    /// The line's progress; nil for any other line.
    public static func parse(_ line: String) -> SeedProgress? {
        guard line.hasPrefix("{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let fields = object["progress"] as? [String: Any] else { return nil }
        let int = { (key: String) in (fields[key] as? NSNumber)?.intValue }
        let filesTotal = int("files_total")
        guard let phase = fields["phase"] as? String ?? (filesTotal != nil ? "copy" : nil) else { return nil }
        return SeedProgress(phase: phase, bytesDone: int("bytes_done"), bytesTotal: int("bytes_total"), objects: int("objects"),
                            objectsTotal: int("objects_total"), filesDone: int("files_done"), filesTotal: filesTotal,
                            fallbackCode: fields["fallback_code"] as? String, installURL: fields["install_url"] as? String)
    }

    /// Least time between two progress values handed on (about 4 a second).
    public static let every: Duration = .milliseconds(250)

    /// A stderr line reader that hands `handle` each progress line, at most one per ``every``,
    /// except a phase change, which always goes. A fallback's code and install link stay on the
    /// copy's lines after it.
    public static func reader(_ handle: @escaping @Sendable (SeedProgress) -> Void) -> @Sendable (String) -> Void {
        let state = Mutex<(last: ContinuousClock.Instant?, phase: String?, installURL: String?, fallbackCode: String?)>((nil, nil, nil, nil))
        return { line in
            guard var progress = parse(line) else { return }
            let now = ContinuousClock.now
            let send = state.withLock { state -> Bool in
                if progress.fallbackCode != nil { (state.fallbackCode, state.installURL) = (progress.fallbackCode, progress.installURL) }
                (progress.fallbackCode, progress.installURL) = (state.fallbackCode, state.installURL)
                let due = state.phase != progress.phase || state.last.map { now - $0 >= every } ?? true
                if due { (state.last, state.phase) = (now, progress.phase) }
                return due
            }
            if send { handle(progress) }
        }
    }

    /// Runs `run` with a stderr line reader (``reader(_:)``) and hands each progress value to `each`
    /// on the main actor while it runs; returns `run`'s answer once both are done. The stream
    /// keeps only the newest value, and ends when `run` returns or throws.
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
