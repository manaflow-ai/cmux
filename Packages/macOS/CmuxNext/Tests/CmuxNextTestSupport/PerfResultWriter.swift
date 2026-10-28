public import Foundation

/// Writes the raw samples of an in-process bench as `cmux-perf-result/v1` (schemas/perf/result-v1.schema.json),
/// so a `swift test` bench is a perf lab story like any app bench (p12-perf-process task 217).
///
/// A bench asks for a writer and records each metric's raw samples, in run order, never a percentile:
///
/// ```swift
/// let results = try PerfResultWriter()
/// try results?.record("swift.lane_item.record_ns", unit: .ns, samples: [record])
/// ```
///
/// Without `CMUX_PERF_RESULT_DIR` there is no writer, so a bench run by hand or by CI is unchanged. With it,
/// the directory must hold the story runner's context (`perf-result-context.json`, written by
/// scripts/perf-lab/stories/swift_benches.py): the story id and the result-v1 fields a test process cannot
/// know (run, build, host, engine, session, features). Each ``record(_:unit:better:samples:)`` writes one
/// result into a new `.ndjson` file of the directory, and the runner validates every file with perf_result.py.
/// Chrome's microbenchmarks report the same way: the test binary writes raw values, and the harness owns the
/// histogram format (`base/test/perf_test_suite.h`, `testing/perf/perf_result_reporter.h`).
public struct PerfResultWriter: Sendable {
    /// The environment variable that names the results directory.
    public static let directoryVariable = "CMUX_PERF_RESULT_DIR"
    /// The story runner's context file inside the results directory.
    public static let contextFileName = "perf-result-context.json"
    /// The result format every record is written in.
    public static let schema = "cmux-perf-result/v1"
    /// The keys of the context: everything of result-v1 but the metric's own fields.
    public static let contextKeys: Set<String> = [
        "story", "run", "build", "host", "engine", "session", "features", "features_hash", "safe_mode", "attachments",
    ]

    /// A result-v1 unit (perf_result.UNITS).
    public enum Unit: String, Sendable, CaseIterable {
        case ms, us, ns, s, count, ratio, percent, bytes
        case bytesPerSecond = "bytes_per_s"
        case milliwatts = "mW"
        case joules = "J"
        case hertz = "Hz"
        case fps
        case perSecond = "per_s"
        case score, unitless
    }

    /// Which direction of a metric is an improvement (result-v1 `better`).
    public enum Better: String, Sendable {
        case lower, higher
    }

    /// Why no result was written.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `CMUX_PERF_RESULT_DIR` is set but the runner's context file is not in it.
        case missingContext(path: String)
        /// The context file is not a JSON object with exactly ``contextKeys`` and a story name.
        case invalidContext(path: String, reason: String)
        /// The metric name is not a result-v1 name (`[A-Za-z0-9][A-Za-z0-9._:-]*`).
        case invalidMetricName(String)
        /// result-v1 needs at least one sample.
        case noSamples(metric: String)
        /// A sample is NaN or infinite, which JSON cannot hold.
        case nonFiniteSample(metric: String)
        /// The result file could not be written.
        case writeFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case let .missingContext(path):
                "\(PerfResultWriter.directoryVariable) is set but \(path) is missing: run the bench through scripts/perf-lab/stories/swift_benches.py"
            case let .invalidContext(path, reason): "\(path): \(reason)"
            case let .invalidMetricName(name): "metric \(name.debugDescription) is not a result-v1 name"
            case let .noSamples(metric): "\(metric): no samples (result-v1 needs at least one)"
            case let .nonFiniteSample(metric): "\(metric): a sample is NaN or infinite"
            case let .writeFailed(path, reason): "\(path): \(reason)"
            }
        }
    }

    /// The directory the results go to.
    public let directory: URL
    /// The context object's JSON bytes, merged into every record.
    private let context: Data

    /// The writer of `environment`'s `CMUX_PERF_RESULT_DIR`, or nil when it is unset or empty.
    ///
    /// - Throws: ``Failure/missingContext(path:)`` or ``Failure/invalidContext(path:reason:)`` when the
    ///   directory is set but has no valid runner context, so a misconfigured lab run fails instead of
    ///   measuring nothing.
    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let path = environment[Self.directoryVariable], !path.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let file = directory.appendingPathComponent(Self.contextFileName)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw Failure.missingContext(path: file.path)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.invalidContext(path: file.path, reason: "not JSON (\(error.localizedDescription))")
        }
        guard let fields = object as? [String: Any] else {
            throw Failure.invalidContext(path: file.path, reason: "not a JSON object")
        }
        let keys = Set(fields.keys)
        guard keys == Self.contextKeys else {
            let missing = Self.contextKeys.subtracting(keys).sorted(), extra = keys.subtracting(Self.contextKeys).sorted()
            throw Failure.invalidContext(path: file.path, reason: "missing keys \(missing), unknown keys \(extra)")
        }
        guard let story = fields["story"] as? String, Self.isName(story) else {
            throw Failure.invalidContext(path: file.path, reason: "story is not a result-v1 name")
        }
        self.directory = directory
        self.context = data
    }

    /// Writes one result: the context with `metric`, `unit`, `better` and the raw `samples` in run order.
    ///
    /// - Returns: the new result file.
    @discardableResult
    public func record(_ metric: String, unit: Unit, better: Better = .lower, samples: [Double]) throws -> URL {
        guard Self.isName(metric) else { throw Failure.invalidMetricName(metric) }
        guard !samples.isEmpty else { throw Failure.noSamples(metric: metric) }
        guard samples.allSatisfy(\.isFinite) else { throw Failure.nonFiniteSample(metric: metric) }
        let file = directory.appendingPathComponent("swift-\(UUID().uuidString.lowercased()).ndjson")
        do {
            // The context was a JSON object when the writer was made, and the file is the writer's own.
            var fields = try JSONSerialization.jsonObject(with: context) as? [String: Any] ?? [:]
            fields["schema"] = Self.schema
            fields["metric"] = metric
            fields["unit"] = unit.rawValue
            fields["better"] = better.rawValue
            fields["samples"] = samples
            fields["target_ref"] = NSNull()
            var line = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
            line.append(0x0A)
            try line.write(to: file, options: .atomic)
        } catch {
            throw Failure.writeFailed(path: file.path, reason: error.localizedDescription)
        }
        return file
    }

    /// ``record(_:unit:better:samples:)`` for integer samples (nanosecond clock reads, counts).
    @discardableResult
    public func record<Sample: BinaryInteger>(_ metric: String, unit: Unit, better: Better = .lower,
                                              samples: [Sample]) throws -> URL {
        try record(metric, unit: unit, better: better, samples: samples.map { Double($0) })
    }

    /// `duration` in milliseconds, the unit most frame and latency metrics use.
    public static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    /// Whether `name` is a result-v1 name: an ASCII letter or digit, then letters, digits, `.`, `_`, `:` or `-`.
    static func isName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, isAlphanumeric(first) else { return false }
        return scalars.dropFirst().allSatisfy { isAlphanumeric($0) || ".:_-".unicodeScalars.contains($0) }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }
}
