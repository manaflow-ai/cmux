public import CmuxNextCompat

/// One hang, stall or blocking call in a report: where it came from, how long it took and its
/// stack (the main thread's; for a ``Kind/blocking`` sample, the stack of the thread that blocked).
public nonisolated struct HangSample: Codable, Sendable, Equatable {
    /// Who measured it.
    public enum Source: String, Codable, Sendable {
        /// `MXHangDiagnostic` (the OS's own hang detector).
        case metrickit
        /// cmux's `MainThreadWatchdog`.
        case watchdog
        /// cmux's blocking detector (``BlockingViolation``, the copy of Chrome's
        /// `base::ScopedBlockingCall`; wire schema 3 only).
        case detector
    }

    /// How long it was.
    public enum Kind: String, Codable, Sendable {
        /// 2 s and more (watchdog), or any MetricKit hang.
        case hang
        /// 250 ms to 2 s (watchdog).
        case stall
        /// A call that may block (file, socket, process, wait) made where blocking is not allowed
        /// (the main thread, a shared pool thread), reported once per call site whatever it took
        /// (detector, wire schema 3 only); ``HangSample/blocking`` says which.
        case blocking
    }

    /// What a ``Kind/blocking`` sample waited on and where it ran: the detector's own closed sets,
    /// written as their raw values (`file-io`, `main`, ...), which never change.
    public struct Blocking: Codable, Sendable, Hashable {
        /// What the call waited on.
        public var kind: BlockingKind
        /// Where the call ran (plans/cmux-next/threading-model.md).
        public var context: BlockingContext

        private enum CodingKeys: String, CodingKey {
            case kind, context
        }

        /// Makes the value from its parts.
        public init(kind: BlockingKind, context: BlockingContext) {
            self.kind = kind
            self.context = context
        }

        /// The kind and context of `violation`.
        public init(_ violation: BlockingViolation) {
            self.init(kind: violation.kind, context: violation.context)
        }

        /// Reads a saved sample; a kind or context this build does not know is a decoding error.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let kind = BlockingKind(rawValue: try container.decode(String.self, forKey: .kind)) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown blocking kind")
            }
            guard let context = BlockingContext(rawValue: try container.decode(String.self, forKey: .context)) else {
                throw DecodingError.dataCorruptedError(forKey: .context, in: container, debugDescription: "unknown blocking context")
            }
            self.init(kind: kind, context: context)
        }

        /// Writes the raw values.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind.rawValue, forKey: .kind)
            try container.encode(context.rawValue, forKey: .context)
        }
    }

    /// The most frames one stack carries.
    public static let maxFrames = 64

    /// Who measured it.
    public var source: Source
    /// How long it was.
    public var kind: Kind
    /// How long it lasted, in milliseconds.
    public var durationMs: Int
    /// Main-thread CPU time during the stall (watchdog stalls); nil when not measured.
    public var cpuMs: Int?
    /// Innermost first, at most ``maxFrames``.
    public var frames: [HangReportFrame]
    /// What a ``Kind/blocking`` sample waited on; nil for every other kind (and absent from its JSON).
    public var blocking: Blocking?

    /// Makes the value from its parts.
    public init(source: Source, kind: Kind, durationMs: Int, cpuMs: Int? = nil, frames: [HangReportFrame],
                blocking: Blocking? = nil) {
        self.source = source
        self.kind = kind
        self.durationMs = max(0, durationMs)
        self.cpuMs = cpuMs.map { max(0, $0) }
        self.frames = Array(frames.prefix(Self.maxFrames))
        self.blocking = blocking
    }

    /// The detector's sample of one blocking call site: no duration (the detector reports the site,
    /// not how long it took), the kind and context, and the stack already reduced to report frames.
    public static func blockingSite(_ detail: Blocking, frames: [HangReportFrame]) -> HangSample {
        HangSample(source: .detector, kind: .blocking, durationMs: 0, frames: frames, blocking: detail)
    }

    private enum CodingKeys: String, CodingKey {
        case source, kind, durationMs, cpuMs, frames
    }

    /// Decodes through ``init(source:kind:durationMs:cpuMs:frames:)``, so a saved pending file is
    /// bounded too (nonnegative times, at most ``maxFrames`` frames).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(Source.self, forKey: .source),
                  kind: try container.decode(Kind.self, forKey: .kind),
                  durationMs: try container.decode(Int.self, forKey: .durationMs),
                  cpuMs: try container.decodeIfPresent(Int.self, forKey: .cpuMs),
                  frames: try container.decode([HangReportFrame].self, forKey: .frames))
    }
}
