public import CmuxNextCompat

/// One hang, stall or blocking call in a report: where it came from, how long it took and its
/// main-thread stack.
public nonisolated struct HangSample: Codable, Sendable, Equatable {
    /// Who measured it.
    public enum Source: String, Codable, Sendable {
        /// `MXHangDiagnostic` (the OS's own hang detector).
        case metrickit
        /// cmux's `MainThreadWatchdog`.
        case watchdog
        /// cmux's main-thread blocking detector (``BlockingViolation``, the copy of Chrome's
        /// `base::ScopedBlockingCall`).
        case detector
    }

    /// How long it was.
    public enum Kind: String, Codable, Sendable {
        /// 2 s and more (watchdog), or any MetricKit hang.
        case hang
        /// 250 ms to 2 s (watchdog).
        case stall
        /// A call that may block (file, socket, process, wait) made on the main thread, reported
        /// once per call site whatever it took (detector); ``HangSample/blocking`` says which.
        case blocking
    }

    /// What a ``Kind/blocking`` sample waited on and where it ran.
    public struct Blocking: Codable, Sendable, Hashable {
        /// The thread or pool the call ran on (the detector's context, plans/cmux-next/threading-model.md).
        public enum Context: String, Codable, Sendable {
            /// The main thread.
            case main
            /// The Swift cooperative pool or a GCD root queue.
            case pool
            /// A `BackgroundWork` lane that may block.
            case lane
            /// A dedicated named queue or thread.
            case dedicated
        }

        /// ``BlockingKind/rawValue`` (`file-io`, `sync-wait`, ...).
        public var kind: String
        /// Where the call ran.
        public var context: Context

        /// Makes the value from its parts.
        public init(kind: BlockingKind, context: Context) {
            self.kind = kind.rawValue
            self.context = context
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
}
