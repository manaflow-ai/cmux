import CmuxNextCompat
public import Foundation

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
