import Foundation

extension CEFTracing {
    /// Which process traced Chromium.
    public nonisolated enum Mode: String, Sendable, Codable {
        /// The app, which ran `CefInitialize`.
        case inProcess = "in_process"
        /// The Chromium Host.
        case host
    }

    /// Chromium's trace clock against the local one (`CLOCK_UPTIME_RAW`, `TraceClock`), read once.
    ///
    /// Chromium's `ts` is `base::TimeTicks` in microseconds, `mach_absolute_time` on macOS, so the offset is
    /// near 0; it is measured anyway, as Chrome's clock sync marker measures it, and the exporter adds it.
    public nonisolated struct ClockSample: Sendable, Equatable, Codable {
        /// Added to a Chromium timestamp (in ns) to put it on the local trace clock.
        public let offsetNanos: Int64
        /// How far the offset may be off: half the local reads' window, plus Chromium's microsecond truncation.
        public let errorBoundNanos: Int64
        /// The local trace clock at the sample.
        public let uptimeNanos: UInt64

        /// Chromium read `chromiumMicros` between the local reads `before` and `after`.
        init(before: UInt64, chromiumMicros: Int64, after: UInt64) {
            let width = after >= before ? after - before : 0
            let midpoint = before + width / 2
            uptimeNanos = midpoint
            offsetNanos = Int64(clamping: midpoint) &- chromiumMicros.multipliedReportingOverflow(by: 1000).partialValue
            errorBoundNanos = Int64(clamping: width / 2 + 1000)
        }

        /// The sample with the smaller error bound (the first on a tie), nil when neither was read.
        static func tighter(_ first: Self?, _ second: Self?) -> Self? {
            guard let first else { return second }
            guard let second else { return first }
            return second.errorBoundNanos < first.errorBoundNanos ? second : first
        }

        enum CodingKeys: String, CodingKey {
            case offsetNanos = "offset_ns"
            case errorBoundNanos = "error_bound_ns"
            case uptimeNanos = "uptime_ns"
        }
    }

    /// A started Chromium trace.
    public nonisolated struct Started: Sendable, Equatable {
        public let mode: Mode
        /// The category filter Chromium records.
        public let categories: String
        /// The offset at the start; nil when the host did not answer the clock read.
        public let clock: ClockSample?
    }

    /// A finished Chromium trace.
    public nonisolated struct Stopped: Sendable, Equatable {
        public let mode: Mode
        /// The JSON trace Chromium wrote.
        public let path: String
        /// The meta.json with the clock offset; nil when it could not be written.
        public let metaPath: String?
        /// The tighter of the start and stop offsets; nil when neither was read.
        public let clock: ClockSample?
    }

    /// The meta.json beside a Chromium trace: how to put its timestamps on the local trace clock.
    nonisolated struct Meta: Equatable, Codable {
        var version = 1
        var source = "chromium"
        var mode: Mode
        /// The app's pid (the file names').
        var pid: Int32
        /// The JSON trace's file name, in the same folder.
        var trace: String
        var categories: String
        /// The buffer the plan asks for; stock CEF cannot apply it (``CEFTracing/requestedBufferKB``).
        var requestedBufferKB: Int
        var bufferApplied = false
        /// `CLOCK_UPTIME_RAW` nanoseconds (`TraceClock`).
        var localClock = "uptime_raw"
        /// `base::TimeTicks` microseconds.
        var chromiumClock = "time_ticks_us"
        /// The offset the exporter adds: the tighter sample.
        var clock: ClockSample?
        /// Every sample read, start then stop.
        var samples: [ClockSample]

        init(mode: Mode, pid: Int32, trace: String, categories: String, requestedBufferKB: Int, clock: ClockSample?,
             samples: [ClockSample]) {
            self.mode = mode
            self.pid = pid
            self.trace = trace
            self.categories = categories
            self.requestedBufferKB = requestedBufferKB
            self.clock = clock
            self.samples = samples
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try encoder.encode(self)
        }

        enum CodingKeys: String, CodingKey {
            case version, source, mode, pid, trace, categories, clock, samples
            case requestedBufferKB = "requested_buffer_kb"
            case bufferApplied = "buffer_applied"
            case localClock = "local_clock"
            case chromiumClock = "chromium_clock"
        }
    }
}
