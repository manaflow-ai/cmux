/// One hang or stall in a report: where it came from, how long it took and its stack (the main
/// thread's, or the hung thread's when ``thread`` names one).
public nonisolated struct HangSample: Codable, Sendable, Equatable {
    /// Who measured it.
    public enum Source: String, Codable, Sendable {
        /// `MXHangDiagnostic` (the OS's own hang detector).
        case metrickit
        /// cmux's `MainThreadWatchdog`, or the hang monitor on its thread for a registered thread.
        case watchdog
    }

    /// How long it was.
    public enum Kind: String, Codable, Sendable {
        /// 2 s and more (watchdog), any MetricKit hang, or a registered thread past its deadline.
        case hang
        /// 250 ms to 2 s (watchdog).
        case stall
    }

    /// The most frames one stack carries.
    public static let maxFrames = 64
    /// The first report schema that carries ``thread``: the schema 2 server refuses unknown keys, so
    /// a thread-hang entry joins a report only from this schema on (task 063).
    public static let threadSchemaVersion = 3
    /// The longest ``thread`` name (the hang-watch catalog's names are shorter).
    public static let maxThreadNameBytes = 48

    /// Who measured it.
    public var source: Source
    /// How long it was.
    public var kind: Kind
    /// How long it lasted, in milliseconds (for a registered thread: how far past its deadline).
    public var durationMs: Int
    /// Main-thread CPU time during the stall (watchdog stalls); nil when not measured.
    public var cpuMs: Int?
    /// Innermost first, at most ``maxFrames``.
    public var frames: [HangReportFrame]
    /// The hang-watch name of the registered thread that hung (`terminal-output`); nil for the main
    /// thread, and then not encoded, so a main-thread entry keeps the schema 2 bytes.
    public var thread: String?

    /// Makes the value from its parts.
    ///
    /// - Parameter thread: A hang-watch catalog name. Anything but lowercase ASCII letters, digits,
    ///   `-`, `_` and `.`, or longer than ``maxThreadNameBytes``, becomes `other`, so no free text
    ///   leaves the Mac.
    public init(source: Source, kind: Kind, durationMs: Int, cpuMs: Int? = nil, frames: [HangReportFrame],
                thread: String? = nil) {
        self.source = source
        self.kind = kind
        self.durationMs = max(0, durationMs)
        self.cpuMs = cpuMs.map { max(0, $0) }
        self.frames = Array(frames.prefix(Self.maxFrames))
        self.thread = thread.map(Self.catalogName)
    }

    /// `name` when it has the shape of a catalog name, else `other`.
    static func catalogName(_ name: String) -> String {
        let shaped = !name.isEmpty && name.utf8.count <= maxThreadNameBytes && name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."): true
            default: false
            }
        }
        return shaped ? name : "other"
    }
}
