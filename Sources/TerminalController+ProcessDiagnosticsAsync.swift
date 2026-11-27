import CmuxControlSocket
import Foundation

/// Async wire adapter for process diagnostics. Only topology collection visits MainActor.
extension TerminalController {
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func v2SystemTopAsync(_ request: ControlRequest) async throws -> String {
        let base = try await v2MainAsync {
            let foundationParams = request.params.mapValues(\.foundationObject)
            return Self.controlCallResult(
                fromLegacy: self.v2SystemTopBasePayload(params: foundationParams)
            )
        }
        guard case .ok(let basePayload) = base,
              case .object(let baseObject) = basePayload,
              case .bool(let includeProcesses)? = baseObject["include_processes"],
              case .array(let rawWindows)? = baseObject["windows"] else {
            return Self.v2Encoder.response(id: request.id, base)
        }
        let processPayload = await processTopPayload(
            windows: .array(rawWindows), includeProcesses: includeProcesses
        )
        let payload = baseObject.merging(processPayload) { _, incoming in incoming }
        return Self.v2Encoder.response(id: request.id, .ok(.object(payload)))
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func processTopPayload(windows: JSONValue, includeProcesses: Bool) async -> [String: JSONValue] {
        guard let windowsObject = windows.foundationObject as? [[String: Any]] else { return [:] }
        let processSnapshot = await CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: includeProcesses, maximumAge: 2
        )
        var windows = windowsObject
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windows)
        let totalPIDs = v2AnnotateTopWindows(
            &windows,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(
            from: processSnapshot,
            totalPIDs: totalPIDs
        )
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windows
        )

        var payload: [String: JSONValue] = [:]
        payload["sample"] = JSONValue(
            foundationObject: processSnapshot.samplePayload()
        ) ?? .object([:])
        payload["totals"] = JSONValue(
            foundationObject: processSnapshot.summaryPayload(for: totalPIDs)
        ) ?? .object([:])
        payload["memory_diagnostic"] = JSONValue(
            foundationObject: memoryDiagnostic
        ) ?? .object([:])
        payload["program_totals"] = JSONValue(
            foundationObject: aggregates.programs
        ) ?? .array([])
        payload["coding_agents"] = JSONValue(
            foundationObject: aggregates.codingAgents
        ) ?? .array([])
        payload["windows"] = JSONValue(
            foundationObject: windows
        ) ?? .array([])
        return payload
    }

}
