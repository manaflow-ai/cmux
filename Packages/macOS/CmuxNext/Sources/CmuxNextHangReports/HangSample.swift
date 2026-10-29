public import CmuxNextCompat

/// One hang, stall or blocking call in a report: where it came from, how long it took and its
/// stack (the main thread's; for a ``Kind/blocking`` sample, the stack of the thread that blocked; for a
/// ``Source/hangWatch`` hang, the stack of the watched thread that hung).
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
        /// cmux's hang watch: a registered thread or lane still inside its scope 2 s past its budget
        /// (Chrome's `HangWatcher`; wire schema 3 only). ``HangSample/thread`` names it.
        case hangWatch = "hangwatch"
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

    /// The watched thread a ``Source/hangWatch`` hang ran on: its registration's catalog name and its kind (Chrome's
    /// `HangWatcher::ThreadType`). Wire schema 3 only (``HangReport/WireSchema/carriesThreadHangs``). Both are cut
    /// to a closed shape on the way in, so a pending file edited on disk sends nothing else.
    public struct WatchedThread: Codable, Sendable, Hashable {
        /// The name written for a registration name outside the allowed shape, and for an unknown kind.
        public static let other = "other"
        /// The kinds a registration has (`HangWatch.ThreadKind`'s case names).
        public static let kinds: Set<String> = ["main", "io", "lane", "renderer", "pool", "control"]
        /// The longest registration name kept.
        public static let maxNameLength = 48

        /// The registration's name (`daemon-reader`, `terminal-output`): a catalog string, never a person's text.
        public var name: String
        /// What the thread runs (one of ``kinds``), or ``other``.
        public var kind: String

        private enum CodingKeys: String, CodingKey {
            case name, kind
        }

        /// The value, with a name outside lowercase letters, digits, `.`, `_` and `-` (or longer than
        /// ``maxNameLength``) and a kind outside ``kinds`` written as ``other``.
        public init(name: String, kind: String) {
            self.name = Self.isCatalogName(name) ? name : Self.other
            self.kind = Self.kinds.contains(kind) ? kind : Self.other
        }

        /// Reads a saved value through ``init(name:kind:)``.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try container.decode(String.self, forKey: .name), kind: try container.decode(String.self, forKey: .kind))
        }

        private static func isCatalogName(_ name: String) -> Bool {
            !name.isEmpty && name.utf8.count <= maxNameLength && name.utf8.allSatisfy { byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
            }
        }
    }

    /// Where the launch was when a watchdog stall or hang before startup completion ran (the watchdog's
    /// `startup_phase` and `startup_task`): the launch phase and the `main()` step or startup
    /// task running. Wire schema 3 only (``HangReport/WireSchema/carriesStartupTag``); the builder keeps only a
    /// known phase and a code-defined task name (``HangReportBuilder/safeStartup(_:)``).
    public struct Startup: Codable, Sendable, Hashable {
        /// The phases a stall record names (`StartupTaskTag.Reading.stallPhase`).
        public static let phases: Set<String> = ["main", "critical", "after_first_frame"]
        /// The task name the builder writes for one it may not send.
        public static let other = "other"

        /// `main` (up to `applicationDidFinishLaunching`), `critical` (to the first frame) or `after_first_frame`.
        public var phase: String
        /// The `main()` step or startup task (a `StaticString` compiled into the app); nil between tasks.
        public var task: String?

        /// Makes the value from its parts.
        public init(phase: String, task: String?) {
            self.phase = phase
            self.task = task
        }

        /// The watchdog's `startup_phase` and `startup_task`; nil when the stall named no phase (after startup).
        public init?(stallPhase: String?, task: String?) {
            guard let stallPhase else { return nil }
            self.init(phase: stallPhase, task: task)
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
    /// The watched thread of a ``Source/hangWatch`` hang (wire `thread`); nil for every other sample, and in
    /// schema 2 (absent from its JSON).
    public var thread: WatchedThread?
    /// Where the launch was during a watchdog stall or hang before startup completed (wire `startup`); nil for
    /// every other sample, and in schema 2 (absent from its JSON).
    public var startup: Startup?
    /// What a ``Source/daemon`` sample is; nil for every other sample (and absent from its JSON).
    public var daemon: Daemon?

    /// Makes the value from its parts.
    public init(source: Source, kind: Kind, durationMs: Int, cpuMs: Int? = nil, frames: [HangReportFrame],
                blocking: Blocking? = nil, mainTask: MainTask? = nil, thread: WatchedThread? = nil, startup: Startup? = nil,
                daemon: Daemon? = nil) {
        self.source = source
        self.kind = kind
        self.durationMs = max(0, durationMs)
        self.cpuMs = cpuMs.map { max(0, $0) }
        self.frames = Array(frames.prefix(Self.maxFrames))
        self.blocking = blocking
        self.mainTask = mainTask
        self.thread = thread
        self.startup = startup
        self.daemon = daemon
    }

    /// The detector's sample of one blocking call site: no duration (the detector reports the site,
    /// not how long it took), the kind and context, and the stack already reduced to report frames.
    public static func blockingSite(_ detail: Blocking, frames: [HangReportFrame]) -> HangSample {
        HangSample(source: .detector, kind: .blocking, durationMs: 0, frames: frames, blocking: detail)
    }

    /// The hang watch's sample of a watched thread still in its scope: how far past its budget it was when sampled,
    /// and the thread's stack already reduced to report frames.
    public static func threadHang(_ thread: WatchedThread, durationMs: Int, frames: [HangReportFrame]) -> HangSample {
        HangSample(source: .hangWatch, kind: .hang, durationMs: durationMs, frames: frames, thread: thread)
    }

    /// The sample of one daemon site: no duration and no stack (the daemon names the site, not where its
    /// thread's stack was), the family, kind and site.
    public static func daemonSite(_ site: DaemonDiagnosticSite) -> HangSample {
        HangSample(source: .daemon, kind: .blocking, durationMs: 0, frames: [], daemon: Daemon(site))
    }

    private enum CodingKeys: String, CodingKey {
        case source, kind, durationMs, cpuMs, frames, blocking, thread, startup, daemon
        case mainTask = "task"
    }

    /// Decodes through ``init(source:kind:durationMs:cpuMs:frames:blocking:mainTask:thread:startup:daemon:)``, so a saved pending file
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
                  thread: try container.decodeIfPresent(WatchedThread.self, forKey: .thread),
                  startup: try container.decodeIfPresent(Startup.self, forKey: .startup),
                  daemon: try container.decodeIfPresent(Daemon.self, forKey: .daemon))
    }
}
