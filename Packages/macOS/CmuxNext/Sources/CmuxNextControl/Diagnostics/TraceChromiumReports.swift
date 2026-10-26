public import CmuxNextSettings
public import CmuxNextTrace

/// Chromium tracing (p09-observability task 051) as ``TraceControl``'s Chromium part: each step's
/// ``CmuxNextTrace/ChromiumTraceReport`` becomes its `chromium` reply member, the shape `cmux trace record` reads
/// (cmux-tui cli/trace/bundle.rs: `path` and `offset_ns`, else `reason` or `error`).
///
/// ```swift
/// let tracing = CEFTracing(directory: blackBox.directory, work: work, engine: { slot.built })
/// let chromium = TraceChromiumReports(start: { await tracing.startReport() }, stop: { await tracing.stopReport() })
/// ```
public struct TraceChromiumReports: TraceChromiumLink {
    private let begin: @Sendable () async -> ChromiumTraceReport
    private let end: @Sendable () async -> ChromiumTraceReport

    /// - Parameters:
    ///   - start: Begins Chromium tracing and reports where it records.
    ///   - stop: Ends it into the recording's folder and reports the JSON file.
    public init(start: @escaping @Sendable () async -> ChromiumTraceReport, stop: @escaping @Sendable () async -> ChromiumTraceReport) {
        begin = start
        end = stop
    }

    public func start() async throws -> CmuxNextSettings.JSONValue { Self.json(await begin()) }

    public func stop() async throws -> CmuxNextSettings.JSONValue { Self.json(await end()) }

    /// The reply member: `state` and every field the report has, under the names the CLI reads.
    static func json(_ report: ChromiumTraceReport) -> CmuxNextSettings.JSONValue {
        let text: [(String, String?)] = [
            ("mode", report.mode), ("categories", report.categories), ("path", report.path), ("meta_path", report.metaPath),
            ("error", report.error), ("detail", report.detail),
        ]
        let numbers: [(String, Int64?)] = [("offset_ns", report.offsetNanos), ("error_bound_ns", report.errorBoundNanos)]
        var members: [String: CmuxNextSettings.JSONValue] = ["state": .string(report.state.rawValue)]
        for case let (key, value?) in text { members[key] = .string(value) }
        for case let (key, value?) in numbers { members[key] = .number(Double(value)) }
        if report.state == .untraced { members["reason"] = members["error"] }
        return .object(members)
    }
}
