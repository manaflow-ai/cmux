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
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)

        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            skipString(in: bytes, index: &index)
            skipNulls(in: bytes, index: &index)
        }

        var workspaceID: UUID?
        var surfaceID: UUID?
        while index < bytes.count {
            skipNulls(in: bytes, index: &index)
            guard index < bytes.count else { break }

            let start = index
            skipString(in: bytes, index: &index)
            guard start < index,
                  let entry = String(bytes: bytes[start..<index], encoding: .utf8) else {
                continue
            }

            if let value = value(inEnvironmentEntry: entry, forKey: "CMUX_WORKSPACE_ID") {
                workspaceID = UUID(uuidString: value) ?? workspaceID
            } else if workspaceID == nil,
                      let value = value(inEnvironmentEntry: entry, forKey: "CMUX_TAB_ID") {
                workspaceID = UUID(uuidString: value)
            } else if let value = value(inEnvironmentEntry: entry, forKey: "CMUX_SURFACE_ID") {
                surfaceID = UUID(uuidString: value) ?? surfaceID
            } else if surfaceID == nil,
                      let value = value(inEnvironmentEntry: entry, forKey: "CMUX_PANEL_ID") {
                surfaceID = UUID(uuidString: value)
            }

            if workspaceID != nil, surfaceID != nil {
                break
            }
        }

        guard workspaceID != nil || surfaceID != nil else { return nil }
        return CmuxTopProcessScope(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    private static func value(inEnvironmentEntry entry: String, forKey key: String) -> String? {
        let prefix = "\(key)="
        guard entry.hasPrefix(prefix) else { return nil }
        let value = String(entry.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func skipString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
    }

    private static func skipNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
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
