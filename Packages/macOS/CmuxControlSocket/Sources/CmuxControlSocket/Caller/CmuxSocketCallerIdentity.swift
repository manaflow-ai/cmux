public import Darwin
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
/// `proc_pidpath` for that pid, and the surface from the caller process's
/// controlling terminal matched against live Ghostty PTYs. Nothing is read out
/// of the request, because a self-reported caller field would be spoofable by
/// exactly the automation the identity is meant to attribute.
///
/// Unresolvable fields stay `nil` and serialize as JSON `null`. They are never
/// omitted and never guessed: a reader must be able to tell "we looked and could
/// not tell" apart from "we did not look".
public struct CmuxSocketCallerIdentity: Sendable, Equatable {
    /// Peer process id from `LOCAL_PEERPID` at accept time.
    public let pid: pid_t?
    /// Executable name for `pid`, resolved at publish time.
    public let processName: String?
    /// Surface the caller is itself running inside, when it runs in a cmux pane.
    public let surfaceId: String?

    public static let unknown = CmuxSocketCallerIdentity(pid: nil, processName: nil, surfaceId: nil)

    public init(pid: pid_t?, processName: String?, surfaceId: String?) {
        self.pid = pid
        self.processName = processName
        self.surfaceId = surfaceId
    }

    /// JSON object attached to every socket-sourced event. Keys are always
    /// present; unresolved values are `NSNull`.
    public var eventPayload: [String: Any] {
        [
            "pid": pid.map { NSNumber(value: Int32($0)) } ?? NSNull(),
            "process_name": processName ?? NSNull(),
            "surface_id": surfaceId ?? NSNull(),
        ]
    }
}

/// A process's start-time identity.
///
/// `LOCAL_PEERPID` is a snapshot taken when the connection was accepted. If that
/// process exits and the kernel recycles its pid before an event is published,
/// a bare pid lookup would describe an unrelated process. A pid plus its start
/// timestamp is unique over time, so every derived field is bound to this token
/// and discarded when it changes.
public struct CmuxSocketCallerGeneration: Hashable, Sendable {
    public let pid: pid_t
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
}

/// Live kernel facts about a process, read in a single `PROC_PIDTBSDINFO` call
/// so the generation and the controlling terminal describe the same instant.
public struct CmuxSocketCallerProcessSnapshot: Sendable {
    public let generation: CmuxSocketCallerGeneration
    /// Controlling terminal device (`e_tdev`), or nil when the process has none.
    public let ttyDevice: Int64?
}

/// Server-side pid → identity lookups for the socket publish path.
///
/// Instantiated and owned at the socket seam and injected into the event-publish
/// path, so the cache is not process-wide ambient state and tests can use their
/// own resolver with no production test hooks.
///
/// State is guarded by an `NSLock` rather than an actor because every caller is
/// a synchronous `nonisolated` function on the control-socket read loop. That
/// loop has no async context to await from, and making it async would reorder
/// event emission relative to the socket response it reports on.
///
/// This never shells out: `proc_pidinfo` and `proc_pidpath` are direct syscalls,
/// and their results are memoized in a bounded cache keyed by the process
/// generation, so a recycled pid cannot inherit a previous process's name.
public final class CmuxSocketCallerResolver: @unchecked Sendable {
    public static let defaultMaxCachedProcessNames = 512

    private let maxCachedProcessNames: Int
    private let lock = NSLock()
    private var cachedNames: [CmuxSocketCallerGeneration: String] = [:]
    private var cacheInsertionOrder: [CmuxSocketCallerGeneration] = []

    public init(maxCachedProcessNames: Int = CmuxSocketCallerResolver.defaultMaxCachedProcessNames) {
        self.maxCachedProcessNames = max(1, maxCachedProcessNames)
    }

    /// Live generation and controlling terminal for `pid`, or nil when the
    /// process is gone. One syscall, so both values describe the same instant.
    public func processSnapshot(pid: pid_t) -> CmuxSocketCallerProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize)) == expectedSize else {
            return nil
        }
        let device = Int64(info.e_tdev)
        return CmuxSocketCallerProcessSnapshot(
            generation: CmuxSocketCallerGeneration(
                pid: pid,
                startSeconds: UInt64(info.pbi_start_tvsec),
                startMicroseconds: UInt64(info.pbi_start_tvusec)
            ),
            ttyDevice: device > 0 ? device : nil
        )
    }

    /// Executable name for a process, or nil when it is gone or opaque.
    ///
    /// Takes a generation rather than a bare pid so the cache cannot serve a
    /// name belonging to a recycled pid.
    public func processName(for generation: CmuxSocketCallerGeneration) -> String? {
        lock.lock()
        let cached = cachedNames[generation]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = uncachedProcessName(pid: generation.pid) else { return nil }

        lock.lock()
        if cachedNames.updateValue(resolved, forKey: generation) == nil {
            cacheInsertionOrder.append(generation)
            // Bounded FIFO: the socket path must not grow memory per caller.
            while cacheInsertionOrder.count > maxCachedProcessNames {
                cachedNames.removeValue(forKey: cacheInsertionOrder.removeFirst())
            }
        }
        lock.unlock()
        return resolved
    }

    /// True when `pid` is still the same process instance `generation` names.
    /// A field derived from a stale generation must be dropped, not published.
    public func generationIsCurrent(_ generation: CmuxSocketCallerGeneration) -> Bool {
        processSnapshot(pid: generation.pid)?.generation == generation
    }

    /// Number of memoized names. Cache state of an injected instance, readable
    /// because the resolver is constructable; not a production test hook.
    public var cachedProcessNameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedNames.count
    }

    private func uncachedProcessName(pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let name = (String(cString: pathBuffer) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
