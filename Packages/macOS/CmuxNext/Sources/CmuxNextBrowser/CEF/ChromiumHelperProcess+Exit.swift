public import Darwin
import CmuxNextWakeups
import Foundation

nonisolated extension ChromiumHelperProcess {
    /// The renderer hosting client `clientID`: its pid and resident size (`ri_resident_size`), read off the main
    /// actor (it lists the app's helpers). Nil when no live renderer has that client id.
    @concurrent
    public static func renderer(client clientID: Int32) async -> (pid: Int32, resident: Int)? {
        guard let helper = list().first(where: { $0.kind == .renderer(clientID: clientID) }),
              let resident = residentBytes(pid: helper.pid) else { return nil }
        return (helper.pid, resident)
    }

    /// Resident bytes of `pid`; nil when it is gone.
    public static func residentBytes(pid: Int32) -> Int? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? Int(info.ri_resident_size) : nil
    }

    /// Waits until process `pid` exits, at most `limit`: whether it did (true at once for a pid already gone).
    @concurrent
    public static func waitForExit(_ pid: Int32, limit: Duration) async -> Bool {
        let (events, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // A process source: Chromium forks and reaps its helpers, so this app has no wait of its own on them.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { continuation.yield(true) }
        source.resume()
        // An exit before the source was armed raises no event.
        if kill(pid, 0) != 0, errno == ESRCH { continuation.yield(true) }
        // The bound: the caller rebuilds its pages after `limit` whether the renderer exited or not.
        let deadline = DemandTimer(owner: "ChromiumHelperProcess.exit")
        deadline.schedule(after: limit) { continuation.yield(false) }
        var exited = false
        for await event in events {
            exited = event
            break
        }
        deadline.cancel()
        source.cancel()
        continuation.finish()
        return exited
    }
}
