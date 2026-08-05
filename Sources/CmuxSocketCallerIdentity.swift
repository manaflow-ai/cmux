import Darwin
import Foundation

/// Who issued a socket-sourced event.
///
/// `source` on an event records the transport (`socket.v1` / `socket.v2`), not
/// a caller, so text injected by `cmux send` was indistinguishable from a human
/// typing it (https://github.com/manaflow-ai/cmux/issues/9611). This carries the
/// attribution instead.
///
/// Every field is resolved server-side from the kernel: the pid comes from
/// `LOCAL_PEERPID` on the accepted connection, the process name from
/// `proc_pidpath`/`proc_bsdinfo` for that pid, and the surface from the caller
/// process's controlling terminal matched against live Ghostty PTYs. Nothing is
/// read out of the request, because a self-reported caller field would be
/// spoofable by exactly the automation the identity is meant to attribute.
///
/// Unresolvable fields stay `nil` and serialize as JSON `null`. They are never
/// omitted and never guessed: a reader must be able to tell "we looked and could
/// not tell" apart from "we did not look".
struct CmuxSocketCallerIdentity: Sendable, Equatable {
    /// Peer process id from `LOCAL_PEERPID` at accept time.
    let pid: pid_t?
    /// Executable name for `pid`, resolved at publish time.
    let processName: String?
    /// Surface the caller is itself running inside, when it runs in a cmux pane.
    let surfaceId: String?

    static let unknown = CmuxSocketCallerIdentity(pid: nil, processName: nil, surfaceId: nil)

    /// JSON object attached to every socket-sourced event. Keys are always
    /// present; unresolved values are `NSNull`.
    var eventPayload: [String: Any] {
        [
            "pid": pid.map { NSNumber(value: Int32($0)) } ?? NSNull(),
            "process_name": processName ?? NSNull(),
            "surface_id": surfaceId ?? NSNull(),
        ]
    }
}

/// Server-side pid → process name lookup for the socket publish path.
///
/// This runs per socket connection on the control-socket hot path, so it never
/// shells out: `proc_pidpath` and `proc_pidinfo` are direct syscalls, and their
/// results are memoized in a bounded cache keyed by pid *and* process start
/// time, so a recycled pid cannot inherit a previous process's name.
enum CmuxSocketCallerResolver {
    /// Identity of a live process for cache keying: a pid alone is not unique
    /// over time, the start timestamp makes it so.
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    static let maxCachedProcessNames = 512

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedNames: [ProcessKey: String] = [:]
    private nonisolated(unsafe) static var cacheInsertionOrder: [ProcessKey] = []

    /// Executable name for `pid`, or nil when the process is gone or opaque.
    static func processName(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize)) == expectedSize else {
            return nil
        }
        let key = ProcessKey(
            pid: pid,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )

        lock.lock()
        let cached = cachedNames[key]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = uncachedProcessName(pid: pid, info: info) else { return nil }

        lock.lock()
        if cachedNames.updateValue(resolved, forKey: key) == nil {
            cacheInsertionOrder.append(key)
            // Bounded FIFO: the socket path must not grow memory per caller.
            while cacheInsertionOrder.count > maxCachedProcessNames {
                cachedNames.removeValue(forKey: cacheInsertionOrder.removeFirst())
            }
        }
        lock.unlock()
        return resolved
    }

    /// Prefer the executable path's last component; `pbi_comm` is a truncated
    /// 16-byte field and is only the fallback when the path is unreadable.
    private static func uncachedProcessName(pid: pid_t, info: proc_bsdinfo) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let path = String(cString: pathBuffer)
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        var info = info
        let comm = withUnsafeBytes(of: &info.pbi_comm) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            guard let base = bytes.baseAddress else { return "" }
            return String(cString: base)
        }
        return comm.isEmpty ? nil : comm
    }

    static func resetCacheForTesting() {
        lock.lock()
        cachedNames.removeAll()
        cacheInsertionOrder.removeAll()
        lock.unlock()
    }

    static var cachedProcessNameCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedNames.count
    }
}
