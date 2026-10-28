public import Darwin
import Foundation
import CmuxNextCompat

/// CPU time, CPU energy and wakeups of one process (`proc_pid_rusage`,
/// `RUSAGE_INFO_V6`), for `debug.wakeups`, `debug.energy`, the busy watchdog
/// and the idle benchmark. Cumulative since the process started: callers
/// diff two samples for rates.
public struct ProcessUsage: Sendable, Equatable {
    /// The process.
    public var pid: pid_t
    /// Its parent process; 0 when it could not be read.
    public var parent: pid_t
    /// Its executable's path; empty when it could not be read.
    public var path: String
    /// User plus system CPU time.
    public var cpuNanos: UInt64
    /// Package idle exits plus interrupt wakeups, as `debug.wakeups` has
    /// always reported them. The first is a subset of the second, so this
    /// counts a package-idle exit twice; ``interruptWakeups`` is the
    /// Chrome-comparable count.
    public var wakeups: UInt64
    /// Interrupt wakeups (`ri_interrupt_wkups`): the counter Chrome reports
    /// as idle wakeups. Chrome reads it for its own process as
    /// `task_power_info.task_interrupt_wakeups` (`task_info(TASK_POWER_INFO)`,
    /// `GetIdleWakeupsPerSecond` in base/process/process_metrics_apple.mm);
    /// `proc_pid_rusage` reads the same kernel counter for any of our pids.
    public var interruptWakeups: UInt64
    /// Wakeups out of package idle (`ri_pkg_idle_wkups`), a subset of
    /// ``interruptWakeups`` (Chrome's `GetPackageIdleWakeupsPerSecond`).
    public var packageIdleWakeups: UInt64
    /// CPU energy (`ri_energy_nj`); work billed to the render server is not in it.
    public var energyNanojoules: UInt64
    /// Its physical memory footprint in bytes (`ri_phys_footprint`, Activity Monitor's Memory).
    public var physFootprint: UInt64
    /// When it was sampled (`CLOCK_UPTIME_RAW` nanoseconds).
    public var uptimeNanos: UInt64

    /// The executable's file name.
    public var name: String { (path as NSString).lastPathComponent }

    /// A usage from its counters (``sample(_:)`` reads them; tests build them).
    public init(pid: pid_t, parent: pid_t, path: String, cpuNanos: UInt64, wakeups: UInt64, interruptWakeups: UInt64,
                packageIdleWakeups: UInt64, energyNanojoules: UInt64, physFootprint: UInt64, uptimeNanos: UInt64) {
        self.pid = pid
        self.parent = parent
        self.path = path
        self.cpuNanos = cpuNanos
        self.wakeups = wakeups
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
        self.energyNanojoules = energyNanojoules
        self.physFootprint = physFootprint
        self.uptimeNanos = uptimeNanos
    }

    /// Samples `pid`; nil when it is gone or not ours. Blocking syscalls: call it off the main actor.
    public static func sample(_ pid: pid_t) -> ProcessUsage? {
        guard let info = rusage(pid) else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let parent = blockingProcPidInfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize ? pid_t(bsd.pbi_ppid) : 0
        return ProcessUsage(pid: pid, parent: parent, path: path(of: pid) ?? "", cpuNanos: ticksToNanos(ticks),
                            wakeups: info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups,
                            interruptWakeups: info.ri_interrupt_wkups, packageIdleWakeups: info.ri_pkg_idle_wkups,
                            energyNanojoules: info.ri_energy_nj,
                            physFootprint: info.ri_phys_footprint, uptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// ``interruptWakeups`` of `pid` alone, from the same `proc_pid_rusage` read as ``sample(_:)``
    /// without its path and parent lookups; nil when it is gone or not ours. One system call that copies
    /// the kernel's counters (the idle histogram reads it on the main actor once per window).
    public static func interruptWakeups(of pid: pid_t) -> UInt64? {
        rusage(pid)?.ri_interrupt_wkups
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? info : nil
    }

    /// CPU share of one core between two samples of the same process (1.0 = 100%).
    public func cpuShare(since earlier: ProcessUsage) -> Double {
        let wall = Double(uptimeNanos &- earlier.uptimeNanos)
        guard wall > 0, cpuNanos >= earlier.cpuNanos else { return 0 }
        return Double(cpuNanos - earlier.cpuNanos) / wall
    }

    /// The executable path of `pid` (`proc_pidpath`); nil when it is gone or not ours. A blocking syscall.
    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The argument vector of `pid` (KERN_PROCARGS2), or [] when unreadable.
    public static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard blockingSysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard blockingSysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and its NUL padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Direct children of `pid`.
    public static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)).filter { $0 > 0 })
    }

    /// Every process of this user whose executable path starts with `prefix`.
    public static func processes(pathPrefix prefix: String) -> [pid_t] {
        let uid = UInt32(getuid())
        let count = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 && (path(of: $0)?.hasPrefix(prefix) ?? false) }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// rusage CPU times are Mach absolute time units.
    static func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        let base = timebase
        guard base.denom != 0 else { return ticks }
        return ticks.multipliedReportingOverflow(by: UInt64(base.numer)).partialValue / UInt64(base.denom)
    }
}

// MARK: - Renderers per tab (p14-energy-124)

extension ProcessUsage {
    /// One Chromium tab renderer: its pid and its `--renderer-client-id` (Chromium's RenderProcessHost id),
    /// as the App's helper classification (`ChromiumHelperProcess`) reads it. Extension renderers are not
    /// tab renderers.
    public struct Renderer: Sendable, Hashable {
        /// The renderer process's pid.
        public var pid: pid_t
        /// Its renderer client id in the browser process.
        public var clientID: Int32

        /// A renderer by its pid and client id.
        public init(pid: pid_t, clientID: Int32) {
            self.pid = pid
            self.clientID = clientID
        }
    }

    /// What one browser tab reports about its renderers, read on the main actor.
    public struct TabRenderers: Sendable, Equatable {
        /// The tab's id.
        public var tab: String
        /// The tab's title.
        public var title: String
        /// The renderer of its main frame, from the fork (`cmux_cef_browser_renderer_pid`); nil without it.
        public var pid: pid_t?
        /// The renderer client ids of all its frames (main frame and out-of-process iframes).
        public var rendererClients: [Int32]

        /// A tab's renderers: its main frame's `pid` and all its frames' `rendererClients`.
        public init(tab: String, title: String, pid: pid_t?, rendererClients: [Int32]) {
            self.tab = tab
            self.title = title
            self.pid = pid
            self.rendererClients = rendererClients
        }

        /// Whether `renderer` hosts the main frame or another frame of this tab.
        public func isServed(by renderer: Renderer) -> Bool {
            if let pid, pid == renderer.pid { return true }
            return rendererClients.contains(renderer.clientID)
        }
    }

    /// One renderer that serves a tab, with every tab it serves (same-site tabs can share one).
    public struct SharedRenderer: Sendable, Equatable {
        /// The renderer.
        public var renderer: Renderer
        /// Its usage.
        public var usage: ProcessUsage
        /// The ids of the tabs it serves, in the order the tabs were given.
        public var tabs: [String]

        /// A renderer, its usage and the tabs it serves.
        public init(renderer: Renderer, usage: ProcessUsage, tabs: [String]) {
            self.renderer = renderer
            self.usage = usage
            self.tabs = tabs
        }
    }

    /// One tab with the usage of each renderer that serves it.
    public struct TabUsage: Sendable, Equatable {
        /// The tab's id.
        public var tab: String
        /// The tab's title.
        public var title: String
        /// The renderers that serve it.
        public var renderers: [SharedRenderer]

        /// A tab and the renderers that serve it.
        public init(tab: String, title: String, renderers: [SharedRenderer]) {
            self.tab = tab
            self.title = title
            self.renderers = renderers
        }

        /// Its renderers' CPU time, summed. A renderer it shares counts in full here and in each other tab
        /// it serves (its ``SharedRenderer/tabs``), so sums over tabs count it more than once.
        public var cpuNanos: UInt64 { renderers.reduce(0) { $0 &+ $1.usage.cpuNanos } }
        /// Its renderers' interrupt wakeups, summed (a shared renderer counts in full, as in ``cpuNanos``).
        public var interruptWakeups: UInt64 { renderers.reduce(0) { $0 &+ $1.usage.interruptWakeups } }
        /// Its renderers' package idle wakeups, summed (a shared renderer counts in full, as in ``cpuNanos``).
        public var packageIdleWakeups: UInt64 { renderers.reduce(0) { $0 &+ $1.usage.packageIdleWakeups } }
        /// Its renderers' energy, in nanojoules, summed (a shared renderer counts in full, as in ``cpuNanos``).
        public var energyNanojoules: UInt64 { renderers.reduce(0) { $0 &+ $1.usage.energyNanojoules } }
    }

    /// The tabs `renderer` serves, in the order of `tabs`.
    public static func tabs(_ tabs: [TabRenderers], servedBy renderer: Renderer) -> [TabRenderers] {
        tabs.filter { $0.isServed(by: renderer) }
    }

    /// Renderer CPU, wakeups and energy per tab: each tab gets every sampled renderer that serves it, and
    /// each of those names all the tabs it serves, so two tabs on one renderer both show its whole usage.
    /// A tab that no sampled renderer serves gets none. O(tabs x renderers).
    public static func perTab(_ tabs: [TabRenderers], renderers: [(renderer: Renderer, usage: ProcessUsage)]) -> [TabUsage] {
        let shared = renderers.map { sample in
            SharedRenderer(renderer: sample.renderer, usage: sample.usage,
                           tabs: Self.tabs(tabs, servedBy: sample.renderer).map(\.tab))
        }
        return tabs.map { tab in
            TabUsage(tab: tab.tab, title: tab.title, renderers: shared.filter { $0.tabs.contains(tab.tab) })
        }
    }
}
