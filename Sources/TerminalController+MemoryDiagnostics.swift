import Foundation

extension TerminalController {
    nonisolated func v2SystemMemory(params: [String: Any]) -> V2CallResult {
        var baseParams = params
        baseParams["include_processes"] = false
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: baseParams)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
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
        let processSnapshot = CmuxTopProcessSnapshot.captureCached(
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
        let resources = MemoryResourceSample(processSnapshot: processSnapshot)
        payload["resource_context"] = v2MainSync {
            resources.payload(
                views: MemoryResourceViewCounts.capture(),
                monitor: MemoryPressureMonitor.shared.resourceDiagnosticPayload()
            )
        }
        return .ok(payload)
    }
}
