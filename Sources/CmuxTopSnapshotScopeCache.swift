import Foundation
import Darwin

struct CmuxTopProcessScopeCacheKey: Hashable {
    let pid: Int
    let startSeconds: Int
    let startMicroseconds: Int
}

private struct CmuxTopProcessScopeCacheValue {
    let scope: CmuxTopProcessScope
}

// CmuxTopProcessSnapshot.capture is intentionally synchronous because it backs
// both async task-manager sampling and sync v2 system.top socket handling. Keep
// this tiny lock isolated to dictionary reads/writes; procargs/sysctl work must
// happen outside the critical section.
private let cmuxTopScopeCacheLock = NSLock()
private var cmuxTopScopeCache: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheValue] = [:]

extension CmuxTopProcessSnapshot {
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
        cmuxTopScopeCacheLock.lock()
        if let cached = cmuxTopScopeCache[cacheKey] {
            cmuxTopScopeCacheLock.unlock()
            return cached.scope
        }
        cmuxTopScopeCacheLock.unlock()

        guard let scope = cmuxScope(for: pid) else {
            return nil
        }

        cmuxTopScopeCacheLock.lock()
        cmuxTopScopeCache[cacheKey] = CmuxTopProcessScopeCacheValue(scope: scope)
        cmuxTopScopeCacheLock.unlock()

        return scope
    }

    static func pruneCMUXScopeCache(activeKeys: Set<CmuxTopProcessScopeCacheKey>) {
        cmuxTopScopeCacheLock.lock()
        cmuxTopScopeCache = cmuxTopScopeCache.filter { activeKeys.contains($0.key) }
        cmuxTopScopeCacheLock.unlock()
    }
}
