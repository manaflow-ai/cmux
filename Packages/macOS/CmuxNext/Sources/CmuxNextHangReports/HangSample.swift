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
        /// The daemon's own detectors (its blocking table and request watchdog), one sample per site it saw
        /// first in its life (``DaemonDiagnosticSite``; wire schema 3 only); ``HangSample/daemon`` says which.
        case daemon
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

    /// What a ``Source/daemon`` sample is: the daemon's own labels (``DaemonDiagnosticSite``), already checked
    /// to hold no path or text, and its site identity (``DaemonDiagnosticSite/key``).
    public struct Daemon: Codable, Sendable, Hashable {
        /// `blocking`, `inversion` or `hang`.
        public var family: String
        /// The daemon's kind (`fs`, `recv`, `priority-inversion`, `request`).
        public var kind: String
        /// The site: crate, file hash and line, or the request method.
        public var site: String

        /// Makes the value from its parts.
        public init(family: String, kind: String, site: String) {
            self.family = family
            self.kind = kind
            self.site = site
        }

        /// The parts of `site`.
        public init(_ site: DaemonDiagnosticSite) {
            self.init(family: site.family.rawValue, kind: site.kind, site: site.key)
        }
    }

    /// The scheduled main-thread task a watchdog hang caught (``MainTaskBoard``'s running task): its owner and
    /// class, or both ``unattributed`` when no scheduled task covered the hang (AppKit's own work, an
    /// unclassified job). Wire schema 3 only (``HangReport/WireSchema/carriesTaskAttribution``); the builder
    /// keeps only an allow-listed owner and class (``HangReportBuilder/safeTask(_:)``).
    public struct MainTask: Codable, Sendable, Hashable {
        /// The owner and class of a hang no scheduled task covered.
        public static let unattributed = "unattributed"
        /// The owner the builder writes for a name it may not send.
        public static let other = "other"

        /// The batch owner, control method or action id that scheduled the task.
        public var owner: String
        /// Its ``MainWorkClass`` (`input`, `frame`, `userBlocking`, ...), or ``unattributed``.
        public var taskClass: String

        private enum CodingKeys: String, CodingKey {
            case owner
            case taskClass = "class"
        }

        /// Makes the value from its parts.
        public init(owner: String, taskClass: String) {
            self.owner = owner
            self.taskClass = taskClass
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
    /// The task a watchdog hang caught (wire `task`); nil for every other sample, and in schema 2 (absent from its JSON).
    public var mainTask: MainTask?
    /// What a ``Source/daemon`` sample is; nil for every other sample (and absent from its JSON).
    public var daemon: Daemon?

    /// Makes the value from its parts.
    public init(source: Source, kind: Kind, durationMs: Int, cpuMs: Int? = nil, frames: [HangReportFrame],
                blocking: Blocking? = nil, mainTask: MainTask? = nil, daemon: Daemon? = nil) {
        self.source = source
        self.kind = kind
        self.durationMs = max(0, durationMs)
        self.cpuMs = cpuMs.map { max(0, $0) }
        self.frames = Array(frames.prefix(Self.maxFrames))
        self.blocking = blocking
        self.mainTask = mainTask
        self.daemon = daemon
    }

    /// The detector's sample of one blocking call site: no duration (the detector reports the site,
    /// not how long it took), the kind and context, and the stack already reduced to report frames.
    public static func blockingSite(_ detail: Blocking, frames: [HangReportFrame]) -> HangSample {
        HangSample(source: .detector, kind: .blocking, durationMs: 0, frames: frames, blocking: detail)
    }

    /// The sample of one daemon site: no duration and no stack (the daemon names the site, not where its
    /// thread's stack was), the family, kind and site.
    public static func daemonSite(_ site: DaemonDiagnosticSite) -> HangSample {
        HangSample(source: .daemon, kind: .blocking, durationMs: 0, frames: [], daemon: Daemon(site))
    }

    private enum CodingKeys: String, CodingKey {
        case source, kind, durationMs, cpuMs, frames, blocking, daemon
        case mainTask = "task"
    }

    /// Decodes through ``init(source:kind:durationMs:cpuMs:frames:blocking:mainTask:daemon:)``, so a saved pending file
    /// is bounded too (nonnegative times, at most ``maxFrames`` frames).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(Source.self, forKey: .source),
                  kind: try container.decode(Kind.self, forKey: .kind),
                  durationMs: try container.decode(Int.self, forKey: .durationMs),
                  cpuMs: try container.decodeIfPresent(Int.self, forKey: .cpuMs),
                  frames: try container.decode([HangReportFrame].self, forKey: .frames),
                  blocking: try container.decodeIfPresent(Blocking.self, forKey: .blocking),
                  mainTask: try container.decodeIfPresent(MainTask.self, forKey: .mainTask),
                  daemon: try container.decodeIfPresent(Daemon.self, forKey: .daemon))
    }
}
