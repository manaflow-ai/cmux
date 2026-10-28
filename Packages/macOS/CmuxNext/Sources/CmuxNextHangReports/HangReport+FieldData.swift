import CmuxNextMetrics
public import CmuxNextTrace

/// Schema 3's field data (plans/cmux-next/chrome-parity/p09-observability.md section 3D and task 063): the
/// catalog histograms recorded since the last report, the stability counts, the black box and one section per
/// earlier launch under that launch's own profile.
///
/// Chrome's model: a UMA log carries each histogram's samples since the last log as bucket deltas
/// (base/metrics/histogram_snapshot_manager.cc), the stability counts with their denominators
/// (components/metrics/stability_metrics_helper.cc), and an earlier run's file as its own log with the profile
/// that file holds (components/metrics/file_metrics_provider.cc). Catalog names and numbers only.
extension HangReport {
    /// The most `histograms[]` one report (and one launch section) carries.
    public static let maxFieldHistograms = 32
    /// The most non-empty buckets one histogram carries.
    public static let maxFieldBuckets = 24
    /// The most launch sections one report carries; later ones wait for the next report.
    public static let maxLaunchSections = 1

    /// The histogram names a report may carry: every ``HistogramID`` of this build's catalog.
    public static let histogramCatalog: Set<String> = Set(HistogramID.allCases.map(\.name))

    /// One catalog histogram's samples since the last report.
    public struct FieldHistogram: Codable, Sendable, Equatable {
        /// One non-empty bucket, on the wire as `[index, count]`.
        public struct Bucket: Codable, Sendable, Equatable {
            /// The bucket's index in the layout ``unit`` and ``max`` name (``HistogramID/Layout/bucketRange(_:)``).
            public var index: Int
            /// Its samples.
            public var count: UInt64

            /// Makes the value from its parts.
            public init(index: Int, count: UInt64) {
                self.index = index
                self.count = count
            }

            public init(from decoder: any Decoder) throws {
                var pair = try decoder.unkeyedContainer()
                index = try pair.decode(Int.self)
                count = try pair.decode(UInt64.self)
                guard pair.isAtEnd, index >= 0 else {
                    throw DecodingError.dataCorruptedError(in: pair, debugDescription: "a bucket is [index, count]")
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var pair = encoder.unkeyedContainer()
                try pair.encode(index)
                try pair.encode(count)
            }
        }

        /// The catalog name (``HistogramID/name``).
        public var name: String
        /// What a sample counts, and so the layout: `us`, `ms`, `kib`, `count` (log-linear), `pct` (linear) or
        /// `enum` (one bucket per value).
        public var unit: String
        /// The non-empty buckets, by index.
        public var buckets: [Bucket]
        /// The samples in ``buckets``.
        public var count: UInt64
        /// Their sum (an estimate when the histogram had more than ``HangReport/maxFieldBuckets`` buckets).
        public var sum: UInt64
        /// The layout's ceiling: its maximum (log-linear and linear) or value count (enumeration); the last
        /// bucket counts every larger sample.
        public var max: Int64

        /// Makes the value from its parts.
        public init(name: String, unit: String, buckets: [Bucket], count: UInt64, sum: UInt64, max: Int64) {
            self.name = name
            self.unit = unit
            self.buckets = buckets
            self.count = count
            self.sum = sum
            self.max = max
        }

        private enum CodingKeys: String, CodingKey {
            case name, unit, buckets, count, sum, max
        }

        /// Refuses a name outside ``HangReport/histogramCatalog``, so a body edited on disk never sends one.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            guard HangReport.histogramCatalog.contains(name) else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "not a catalog histogram")
            }
            unit = try container.decode(String.self, forKey: .unit)
            buckets = try container.decode([Bucket].self, forKey: .buckets)
            count = try container.decode(UInt64.self, forKey: .count)
            sum = try container.decode(UInt64.self, forKey: .sum)
            max = try container.decode(Int64.self, forKey: .max)
        }
    }

    /// `stability{}`: launches with their active time (the denominators), and how runs and child processes
    /// ended. Each map holds only non-zero counts, by its closed set's names.
    public struct Stability: Codable, Sendable, Equatable {
        /// App launches (`stability.launch`).
        public var launch: UInt64 = 0
        /// Seconds the app was active (`stability.active_seconds`).
        public var activeSeconds: UInt64 = 0
        /// Unclean exits by ``HistogramID/UncleanExit`` (`crash`, `system_shutdown`, `killed`, `fatal_hang`).
        public var uncleanExit: [String: UInt64] = [:]
        /// Child process exits by ``HistogramID/ProcessKind``, then ``HistogramID/ChildExit``.
        public var childExit: [String: [String: UInt64]] = [:]
        /// Daemons that stopped answering, by the ``HistogramID/MethodClass`` of their last request.
        public var daemonUnresponsive: [String: UInt64] = [:]

        /// Makes an empty value.
        public init() {}

        /// Whether nothing was counted.
        public var isEmpty: Bool {
            launch == 0 && activeSeconds == 0 && uncleanExit.isEmpty && childExit.isEmpty && daemonUnresponsive.isEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case launch
            case activeSeconds = "active_seconds"
            case uncleanExit = "unclean_exit"
            case childExit = "child_exit"
            case daemonUnresponsive = "daemon_unresponsive"
        }

        /// A missing count or map is 0 or empty.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            launch = try container.decodeIfPresent(UInt64.self, forKey: .launch) ?? 0
            activeSeconds = try container.decodeIfPresent(UInt64.self, forKey: .activeSeconds) ?? 0
            uncleanExit = try container.decodeIfPresent([String: UInt64].self, forKey: .uncleanExit) ?? [:]
            childExit = try container.decodeIfPresent([String: [String: UInt64]].self, forKey: .childExit) ?? [:]
            daemonUnresponsive = try container.decodeIfPresent([String: UInt64].self, forKey: .daemonUnresponsive) ?? [:]
        }

        /// Only the non-zero counts and non-empty maps.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if launch != 0 { try container.encode(launch, forKey: .launch) }
            if activeSeconds != 0 { try container.encode(activeSeconds, forKey: .activeSeconds) }
            if !uncleanExit.isEmpty { try container.encode(uncleanExit, forKey: .uncleanExit) }
            if !childExit.isEmpty { try container.encode(childExit, forKey: .childExit) }
            if !daemonUnresponsive.isEmpty { try container.encode(daemonUnresponsive, forKey: .daemonUnresponsive) }
        }
    }

    /// One `blackbox[]` event: a trace record of the app, the daemon or a host that may leave the Mac
    /// (``TraceBlackBoxUpload``), with no key-timing, per-key PTY or flow record.
    public struct BlackBoxEvent: Codable, Sendable, Equatable {
        /// Microseconds after the first event of the list (the rings share `CLOCK_UPTIME_RAW`).
        public var tUs: UInt64
        /// The process whose ring held it (``HangReport/blackBoxProcesses``).
        public var process: String
        /// The trace catalog name.
        public var name: String
        /// The phase: Chrome's one-letter `TRACE_EVENT_PHASE_*` code.
        public var phase: String
        /// The first argument (absent when 0).
        public var arg0: UInt64?
        /// The second argument (absent when 0).
        public var arg1: UInt64?

        /// Makes the value from its parts.
        public init(tUs: UInt64, process: String, name: String, phase: String, arg0: UInt64? = nil, arg1: UInt64? = nil) {
            self.tUs = tUs
            self.process = process
            self.name = name
            self.phase = phase
            self.arg0 = arg0
            self.arg1 = arg1
        }

        private enum CodingKeys: String, CodingKey {
            case tUs = "t_us"
            case process, name, phase, arg0, arg1
        }
    }

    /// The `process` names of ``BlackBoxEvent``, by ring role.
    public static func blackBoxProcess(_ role: TraceRuntime.Role) -> String {
        switch role {
        case .app: "app"
        case .daemon: "daemon"
        case .holder: "holder"
        case .terminalHost: "terminal_host"
        case .acpmux: "acpmux"
        case .chromiumHost: "chromium_host"
        case .cli: "cli"
        case .agentHost: "agent_host"
        case .appHost: "app_host"
        case .browserHost: "browser_host"
        }
    }

    /// Every ``BlackBoxEvent/process`` value.
    public static let blackBoxProcesses: Set<String> = Set(TraceRuntime.Role.allCases.map(blackBoxProcess))

    /// One earlier launch's samples under its own profile (task 053's fold).
    public struct LaunchSection: Codable, Sendable, Equatable {
        /// The profile of the launch that recorded the samples.
        public struct Profile: Codable, Sendable, Equatable {
            /// Its version (digits and dots).
            public var version: String
            /// Its build number.
            public var build: String
            /// `nightly`, `dev`, `rc` or `release`.
            public var channel: String
            /// Its macOS version (digits and dots).
            public var os: String
            /// The day its build was made (`yyyy-MM-dd`).
            public var buildDay: String

            /// Makes the value from its parts.
            public init(version: String, build: String, channel: String, os: String, buildDay: String) {
                self.version = version
                self.build = build
                self.channel = channel
                self.os = os
                self.buildDay = buildDay
            }

            private enum CodingKeys: String, CodingKey {
                case version, build, channel, os
                case buildDay = "build_day"
            }
        }

        /// A UUID derived from the source launch's id: the server counts a section sent twice once, and the
        /// launch's pid, start time and boot session never leave the Mac.
        public var id: String
        /// The launch's profile.
        public var profile: Profile
        /// Its catalog histograms, as ``HangReport/histograms``.
        public var histograms: [FieldHistogram]
        /// Its stability counts; nil when it counted none.
        public var stability: Stability?

        /// Makes the value from its parts.
        public init(id: String, profile: Profile, histograms: [FieldHistogram], stability: Stability?) {
            self.id = id
            self.profile = profile
            self.histograms = histograms
            self.stability = stability
        }
    }
}
