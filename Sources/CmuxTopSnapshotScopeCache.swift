import Foundation
import Darwin
import os

nonisolated struct CmuxTopProcessScopeCacheKey: Hashable {
    let pid: Int
    let startSeconds: Int
    let startMicroseconds: Int
}

private nonisolated struct CmuxTopProcessScopeCacheValue {
    let scope: CmuxTopProcessScope
}

// CmuxTopProcessSnapshot.capture is intentionally synchronous because it backs
// both async task-manager sampling and sync v2 system.top socket handling. Keep
// this tiny lock isolated to dictionary reads/writes; procargs/sysctl work must
// happen outside the critical section.
private nonisolated let cmuxTopScopeCache = OSAllocatedUnfairLock(
    initialState: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheValue]()
)

nonisolated extension CmuxTopProcessSnapshot {
    static func scopeCacheKey(from kinfo: kinfo_proc) -> CmuxTopProcessScopeCacheKey {
        let startTime = kinfo.kp_proc.p_un.__p_starttime
        return CmuxTopProcessScopeCacheKey(
            pid: Int(kinfo.kp_proc.p_pid),
            startSeconds: Int(startTime.tv_sec),
            startMicroseconds: Int(startTime.tv_usec)
        )
    }

    static func cachedCMUXScope(
        for pid: Int,
        cacheKey: CmuxTopProcessScopeCacheKey
    ) -> CmuxTopProcessScope? {
        if let cached = cmuxTopScopeCache.withLock({ cache in cache[cacheKey] }) {
            return cached.scope
        }

        guard let scope = cmuxScope(for: pid, expectedCacheKey: cacheKey) else {
            return nil
        }

        cmuxTopScopeCache.withLock { cache in
            cache[cacheKey] = CmuxTopProcessScopeCacheValue(scope: scope)
        }

        return scope
    }

    static func pruneCMUXScopeCache(activeKeys: Set<CmuxTopProcessScopeCacheKey>) {
        cmuxTopScopeCache.withLock { cache in
            cache = cache.filter { activeKeys.contains($0.key) }
        }
    }

    private static func cmuxScope(
        for pid: Int,
        expectedCacheKey: CmuxTopProcessScopeCacheKey
    ) -> CmuxTopProcessScope? {
        guard let currentProcess = kinfoProc(for: pid),
              scopeCacheKey(from: currentProcess) == expectedCacheKey else {
            return nil
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        guard let currentProcess = kinfoProc(for: pid),
              scopeCacheKey(from: currentProcess) == expectedCacheKey else {
            return nil
        }

        return cmuxScope(fromKernProcArgs: Array(buffer.prefix(Int(size))))
    }

    static func cmuxScope(fromKernProcArgs bytes: [UInt8]) -> CmuxTopProcessScope? {
        guard let process = processArgumentsAndEnvironment(fromKernProcArgs: bytes) else {
            return nil
        }
        return cmuxScope(arguments: process.arguments, environment: process.environment)
    }

    static func cmuxScope(arguments: [String], environment: [String: String]) -> CmuxTopProcessScope? {
        if let environmentScope = cmuxScopeFromEnvironment(environment) {
            return environmentScope
        }
        if let hookScope = cmuxHookMonitorScope(arguments: arguments) {
            return hookScope
        }
        return nil
    }

    private static func cmuxScopeFromEnvironment(_ environment: [String: String]) -> CmuxTopProcessScope? {
        let workspaceID = uuidValue(in: environment, keys: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID"])
        let surfaceID = uuidValue(in: environment, keys: ["CMUX_SURFACE_ID", "CMUX_PANEL_ID"])
        guard workspaceID != nil || surfaceID != nil else { return nil }
        return CmuxTopProcessScope(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            attributionReason: "cmux-environment"
        )
    }

    private static func cmuxHookMonitorScope(arguments: [String]) -> CmuxTopProcessScope? {
        guard containsSubcommandPath(["hooks", "codex", "monitor"], in: arguments) else {
            return nil
        }
        let workspaceID = uuidOptionValue(in: arguments, names: ["--workspace"])
        let surfaceID = uuidOptionValue(in: arguments, names: ["--surface", "--panel"])
        guard workspaceID != nil || surfaceID != nil else { return nil }
        return CmuxTopProcessScope(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            attributionReason: "cmux-hook-arguments"
        )
    }

    private static func containsSubcommandPath(_ path: [String], in arguments: [String]) -> Bool {
        let normalizedPath = path.map { $0.lowercased() }
        guard !normalizedPath.isEmpty, arguments.count >= normalizedPath.count + 1 else { return false }
        let executableName = URL(fileURLWithPath: arguments[0])
            .lastPathComponent
            .lowercased()
        guard executableName == "cmux" else { return false }
        let subcommands = arguments
            .dropFirst()
            .prefix(normalizedPath.count)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Array(subcommands) == normalizedPath
    }

    private static func uuidValue(in environment: [String: String], keys: [String]) -> UUID? {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let uuid = UUID(uuidString: raw) else {
                continue
            }
            return uuid
        }
        return nil
    }

    private static func uuidOptionValue(in arguments: [String], names: Set<String>) -> UUID? {
        for index in arguments.indices {
            let argument = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
            for name in names {
                let prefix = "\(name)="
                guard argument.hasPrefix(prefix) else { continue }
                let raw = String(argument.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, let uuid = UUID(uuidString: raw) else { continue }
                return uuid
            }

            guard names.contains(argument) else { continue }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { continue }
            let raw = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let uuid = UUID(uuidString: raw) else { continue }
            return uuid
        }
        return nil
    }

    private static func kinfoProc(for pid: Int) -> kinfo_proc? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &process, &length, nil, 0)
        guard result == 0,
              length >= MemoryLayout<kinfo_proc>.stride,
              process.kp_proc.p_pid == pid_t(pid) else {
            return nil
        }
        return process
    }
}
