public import Foundation

/// The daemon's own startup timeline (`identify {startup_marks: true}`, `startup-marks-v1`, cmux-tui
/// spec/commands.md): when its `main` began and the first time it reached each step of its start, which the app
/// records as `daemon.<step>` launch marks beside its own (``DaemonLaunchTimings/record(_:)``). A step the daemon has
/// not reached, or one this build does not know, is absent.
public struct DaemonStartupMarks: Sendable, Equatable {
    /// The daemon's steps in the order it reaches them; each raw value is the step's wire field.
    public enum Step: String, CaseIterable, Sendable {
        case configLoaded = "config_loaded"
        case ownerPrepared = "owner_prepared"
        case socketBound = "socket_bound"
        case muxRestored = "mux_restored"
        case ownerEventLoop = "owner_event_loop"
        case websocketReady = "websocket_ready"
        case launchSnapshotWriterStarted = "launch_snapshot_writer_started"
        case lifecycleReady = "lifecycle_ready"
        case firstIdentifyServed = "first_identify_served"

        /// The step's launch mark name.
        public var markName: String { "daemon.\(rawValue)" }
    }

    /// The launch mark name of ``mainStart``.
    public static let mainStartMarkName = "daemon.main_start"

    /// When the daemon's `main` began, by the wall clock.
    public var mainStart: Date
    /// When the daemon first reached each step it reached.
    public var reached: [Step: Date]

    public init(mainStart: Date, reached: [Step: Date]) {
        self.mainStart = mainStart
        self.reached = reached
    }

    /// `daemon.main_start` and each reached step's mark, in step order.
    public var launchMarks: [(name: String, date: Date)] {
        var marks: [(name: String, date: Date)] = [(name: Self.mainStartMarkName, date: mainStart)]
        for step in Step.allCases {
            if let date = reached[step] { marks.append((name: step.markName, date: date)) }
        }
        return marks
    }
}

extension DaemonStartupMarks: Decodable {
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Steps are microseconds after `main_start_unix_us` (the daemon's monotonic clock), so a wall-clock step
    /// during the daemon's start moves none of them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let origin = try c.decode(UInt64.self, forKey: Field(stringValue: "main_start_unix_us"))
        func date(_ micros: UInt64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
        mainStart = date(origin)
        var reached: [Step: Date] = [:]
        for step in Step.allCases {
            if let offset = try c.decodeIfPresent(UInt64.self, forKey: Field(stringValue: step.rawValue)) {
                reached[step] = date(origin &+ offset)
            }
        }
        self.reached = reached
    }
}

/// `identify {startup_marks: true}`: the serving daemon's startup timeline, read once per launch after the first
/// snapshot (``DaemonConnectMarks``). A daemon without `startup-marks-v1` is never asked.
public struct DaemonStartupMarksRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// Nil when no daemon serves the mux.
        public var startupMarks: DaemonStartupMarks?

        enum CodingKeys: String, CodingKey { case startupMarks = "startup_marks" }
    }

    public static let commandName: DaemonCommandName = "identify"
    public static let capability = "startup-marks-v1"
    public static var requiredCapability: String? { capability }
    private let startupMarks = true

    public init() {}

    enum CodingKeys: String, CodingKey { case startupMarks = "startup_marks" }
}
