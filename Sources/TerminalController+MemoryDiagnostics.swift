import CmuxControlSocket
import Foundation

extension TerminalController {
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func v2SystemMemory(params: [String: Any]) async -> V2CallResult {
        var baseParams = params
        baseParams["include_processes"] = false
        let paramsValue = baseParams.compactMapValues { JSONValue(foundationObject: $0) }
        let typedBase = await v2MainAsync {
            self.v2RefreshKnownRefs()
            return Self.controlCallResult(fromLegacy: self.v2SystemTopBasePayload(params: paramsValue.mapValues(\.foundationObject)))
        }
        guard case .ok(let value) = typedBase else {
            if case .err(let code, let message, let data) = typedBase { return .err(code: code, message: message, data: data?.foundationObject) }
            return .err(code: "internal_error", message: "Invalid system.memory payload", data: nil)
        }
        guard var payload = value.foundationObject as? [String: Any],
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.memory payload", data: nil)
        }
        func intParam(_ key: String) -> Int? {
            if let i = params[key] as? Int { return i }
            if let n = params[key] as? NSNumber {
                guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                let value = n.doubleValue
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      value >= Double(Int.min),
                      value <= Double(Int.max) else {
                    return nil
                }
                return n.intValue
            }
            if let s = params[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil else {
                    return nil
                }
                return Int(trimmed)
            }
            return nil
        }
        var invalidLimitKey: String?
        func groupLimitParam(_ key: String) -> Int? {
            guard params[key] != nil else { return nil }
            guard let value = intParam(key), (1...100).contains(value) else {
                invalidLimitKey = key
                return nil
            }
            return value
        }
        let topGroupLimitValue = groupLimitParam("top_group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let groupLimitValue = groupLimitParam("group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let topGroupLimit = topGroupLimitValue ?? groupLimitValue ?? 12
        let processSnapshot = await CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: true,
            maximumAge: 2
        )
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        _ = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: false
        )
        payload["sample"] = processSnapshot.samplePayload()
        payload["memory_diagnostic"] = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes,
            topGroupLimit: topGroupLimit
        )
        let resources = await MemoryResourceSample(processSnapshot: processSnapshot)
        let resourceContext = await v2MainAsync {
            JSONValue(foundationObject: resources.payload(
                views: MemoryResourceViewCounts.capture(),
                monitor: MemoryPressureMonitor.shared.resourceDiagnosticPayload()
            )) ?? .object([:])
        }
        payload["resource_context"] = resourceContext.foundationObject
        return .ok(payload)
    }
}
