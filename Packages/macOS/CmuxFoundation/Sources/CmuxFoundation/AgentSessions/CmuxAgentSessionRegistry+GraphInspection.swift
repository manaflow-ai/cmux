import Foundation
import SQLite3

extension CmuxAgentSessionRegistry {
    /// Bounded graph metadata for canonical rows.
    public struct HookGraphNodeMetrics: Equatable, Sendable {
        public var graphNodeCount: Int

        public init(graphNodeCount: Int) {
            self.graphNodeCount = graphNodeCount
        }
    }

    public struct HookGraphNodeInspectionLimitError: Error, Equatable, Sendable {
        public var provider: String
        public var observed: Int64
        public var maximum: Int64

        public init(provider: String, observed: Int64, maximum: Int64) {
            self.provider = provider
            self.observed = observed
            self.maximum = maximum
        }
    }

    public struct HookGraphNodeMalformedRecordError: Error, Equatable, Sendable {
        public var provider: String
        public var sessionID: String?

        public init(provider: String, sessionID: String?) {
            self.provider = provider
            self.sessionID = sessionID
        }
    }

    public struct HookInspectionGraphUnionLimitError: Error, Equatable, Sendable {
        public var provider: String
        public var path: String
        public var observed: Int64
        public var maximum: Int64

        public init(
            provider: String,
            path: String,
            observed: Int64,
            maximum: Int64
        ) {
            self.provider = provider
            self.path = path
            self.observed = observed
            self.maximum = maximum
        }
    }

    /// Streams canonical runs through SQLite JSON cursors. This does not load
    /// provider record blobs into a Foundation object graph.
    public func hookGraphNodeMetrics(
        provider: String,
        maximumGraphNodes: Int = 20_000
    ) throws -> HookGraphNodeMetrics {
        let maximumGraphNodes = max(0, maximumGraphNodes)
        return try withDatabase { database in
            try ensureHookHotPathSchema(database)
            return try readTransaction(database) {
                try hookGraphNodeMetrics(
                    database: database,
                    provider: provider,
                    maximumGraphNodes: maximumGraphNodes
                )
            }
        }
    }

    func validateHookInspectionGraph(
        database: OpaquePointer,
        providers: [String],
        admissions: [HookLegacySourceAdmission],
        maximumGraphNodes: Int
    ) throws {
        let maximumGraphNodes = max(0, maximumGraphNodes)
        if admissions.isEmpty {
            // Canonical rows have already passed the registry writer's storage
            // boundaries. Keep the current-sidecar path independent of record JSON
            // size: list projects one row per session, while tree enforces its exact
            // filtered node limit while streaming decoded records.
            var canonicalRecordCount = 0
            for provider in providers {
                let next = canonicalRecordCount.addingReportingOverflow(
                    try readRecordCount(database: database, provider: provider)
                )
                canonicalRecordCount = next.overflow ? .max : next.partialValue
                guard canonicalRecordCount <= maximumGraphNodes else {
                    throw HookGraphNodeInspectionLimitError(
                        provider: provider,
                        observed: Int64(canonicalRecordCount),
                        maximum: Int64(maximumGraphNodes)
                    )
                }
            }
            return
        }

        let admissionByProvider = Dictionary(
            admissions.map { ($0.source.provider, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var graphNodeCount = 0
        for provider in providers {
            let metrics: HookGraphNodeMetrics
            do {
                metrics = try hookGraphNodeMetrics(
                    database: database,
                    provider: provider,
                    maximumGraphNodes: max(0, maximumGraphNodes - graphNodeCount)
                )
            } catch let error as HookGraphNodeInspectionLimitError {
                let observed = Int64(graphNodeCount).addingReportingOverflow(error.observed)
                let totalObserved = observed.overflow ? Int64.max : observed.partialValue
                if let admission = admissionByProvider[provider] {
                    throw HookInspectionGraphUnionLimitError(
                        provider: provider,
                        path: admission.source.url.path,
                        observed: totalObserved,
                        maximum: Int64(maximumGraphNodes)
                    )
                }
                throw HookGraphNodeInspectionLimitError(
                    provider: provider,
                    observed: totalObserved,
                    maximum: Int64(maximumGraphNodes)
                )
            }
            let next = graphNodeCount.addingReportingOverflow(metrics.graphNodeCount)
            graphNodeCount = next.overflow ? .max : next.partialValue
        }
    }

    private func hookGraphNodeMetrics(
        database: OpaquePointer,
        provider: String,
        maximumGraphNodes: Int
    ) throws -> HookGraphNodeMetrics {
        let statement = try prepare(
            database,
            """
            SELECT session.session_id,
                   json_type(session.record_json),
                   json_type(session.record_json, '$.sessionId'),
                   json_extract(session.record_json, '$.sessionId'),
                   json_type(session.record_json, '$.runs'),
                   CASE
                     WHEN json_type(session.record_json, '$.runs') = 'array'
                     THEN json_array_length(session.record_json, '$.runs')
                     ELSE NULL
                   END,
                   CASE
                     WHEN json_type(session.record_json, '$.runs') = 'array'
                          AND json_array_length(session.record_json, '$.runs') > 0
                     THEN json_extract(run.value, '$.runId')
                     WHEN json_type(session.record_json, '$.runId') = 'text'
                     THEN json_extract(session.record_json, '$.runId')
                     ELSE 'session:' || session.provider || ':' || session.session_id
                   END,
                   CASE WHEN run.value IS NULL THEN NULL ELSE json_type(run.value) END,
                   CASE
                     WHEN run.value IS NULL THEN NULL
                     ELSE json_type(run.value, '$.runId')
                   END,
                   json_type(session.record_json, '$.runId')
            FROM agent_sessions AS session
            LEFT JOIN json_each(
                CASE
                  WHEN json_type(session.record_json, '$.runs') = 'array'
                  THEN session.record_json
                  ELSE NULL
                END,
                '$.runs'
            ) AS run
            WHERE session.provider = ?1
            ORDER BY session.session_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)

        var graphNodeCount = 0
        var currentSessionID: String?
        var currentRunIDs: Set<String> = []

        while try stepRow(
            statement,
            database: database,
            operation: "inspect hook graph nodes"
        ) {
            guard let sessionID = text(statement, column: 0),
                text(statement, column: 1) == "object",
                text(statement, column: 2) == "text",
                text(statement, column: 3) == sessionID,
                let runID = text(statement, column: 6)
            else {
                throw HookGraphNodeMalformedRecordError(
                    provider: provider,
                    sessionID: text(statement, column: 0)
                )
            }
            let runsType = text(statement, column: 4)
            guard runsType == nil || runsType == "null" || runsType == "array" else {
                throw HookGraphNodeMalformedRecordError(
                    provider: provider,
                    sessionID: sessionID
                )
            }
            let runCount =
                runsType == "array"
                ? Int(sqlite3_column_int64(statement, 5))
                : 0
            let recordRunIDType = text(statement, column: 9)
            guard
                recordRunIDType == nil
                    || recordRunIDType == "null"
                    || recordRunIDType == "text",
                runCount == 0
                    || (text(statement, column: 7) == "object"
                        && text(statement, column: 8) == "text")
            else {
                throw HookGraphNodeMalformedRecordError(
                    provider: provider,
                    sessionID: sessionID
                )
            }
            if currentSessionID != sessionID {
                currentSessionID = sessionID
                currentRunIDs.removeAll(keepingCapacity: true)
            }
            guard currentRunIDs.insert(runID).inserted else { continue }
            graphNodeCount += 1
            guard graphNodeCount <= maximumGraphNodes else {
                throw HookGraphNodeInspectionLimitError(
                    provider: provider,
                    observed: Int64(graphNodeCount),
                    maximum: Int64(maximumGraphNodes)
                )
            }
        }
        return HookGraphNodeMetrics(graphNodeCount: graphNodeCount)
    }
}
