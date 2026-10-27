public import Darwin

/// A Mach task role a cmux process asks for: the Swift twin of `cmux_threads::process_role`
/// (cmux-tui/crates/cmux-threads/src/process_role.rs), for the Chromium host side.
///
/// Chromium's children call `SetCurrentTaskDefaultRole` at start (base/process/process_mac.cc):
/// `TASK_FOREGROUND_APPLICATION` with latency and throughput tier 0, which is ``applyDefault()``.
/// `Process::SetPriority` moves a child to `TASK_BACKGROUND_APPLICATION` with tier 5 timers and
/// throughput for `kBestEffort`, which is ``background``. ``backgroundSuppressed`` adds `PRIO_DARWIN_BG`
/// (low-priority CPU, throttled disk and network I/O); ``foreground`` and ``background`` clear it.
///
/// XNU keeps two `PRIO_DARWIN_BG` flags per task (bsd/kern/kern_resource.c, `do_background_proc`): the internal
/// one a process sets on itself (``apply()``) and the external one another process sets by pid
/// (``applySuppression(toChild:)``) or a child inherits from a suppressed parent. Either suppresses the task, and a
/// process can clear only its own internal one. ``darwinBackground(pid:)`` reads both.
///
/// ```swift
/// try ProcessRole.applyDefault()
/// try ProcessRole.backgroundSuppressed.apply()
/// try ProcessRole.foreground.apply()   // PRIO_DARWIN_BG is off again
/// ```
public enum ProcessRole: Sendable, Equatable {
    /// `TASK_FOREGROUND_APPLICATION`, tier 0 timers and throughput, no `PRIO_DARWIN_BG`.
    case foreground
    /// `TASK_BACKGROUND_APPLICATION`, tier 5 timers and throughput, no `PRIO_DARWIN_BG`.
    case background
    /// ``background`` plus `PRIO_DARWIN_BG`.
    case backgroundSuppressed

    /// Chromium's `SetCurrentTaskDefaultRole` for this process. `PRIO_DARWIN_BG` stays as inherited.
    ///
    /// - Throws: ``ProcessRoleError/category(_:)`` or ``ProcessRoleError/baseQoS(_:)`` when the kernel refuses.
    public static func applyDefault() throws(ProcessRoleError) {
        try ProcessRole.foreground.setPolicies()
    }

    /// Moves this process to this role. Leaving suppression clears this process's internal `PRIO_DARWIN_BG`
    /// before the role changes; entering it sets that flag last. The external flag (a parent's suppression, or
    /// inherited) stays: only another process can clear it.
    ///
    /// - Throws: The first ``ProcessRoleError`` the kernel returns.
    public func apply() throws(ProcessRoleError) {
        let suppressed = self == .backgroundSuppressed
        if !suppressed { try Self.setDarwinBackground(false, pid: 0) }
        try setPolicies()
        if suppressed { try Self.setDarwinBackground(true, pid: 0) }
    }

    /// Sets or clears the external `PRIO_DARWIN_BG` flag of a child this process started, as this role has it.
    /// A parent holds no task port of the child, so the child's task role is the child's own (``applyDefault()``).
    ///
    /// - Parameter pid: A running child of this process.
    /// - Throws: ``ProcessRoleError/darwinBackground(_:)`` with the errno.
    public func applySuppression(toChild pid: pid_t) throws(ProcessRoleError) {
        try Self.setDarwinBackground(self == .backgroundSuppressed, pid: id_t(pid))
    }

    /// This process's `task_role_t` (`TASK_CATEGORY_POLICY`): 1 foreground, 2 background, nil when the read failed.
    public static func currentTaskRole() -> Int32? {
        var role: integer_t = 0
        var count = mach_msg_type_number_t(1)
        var getDefault = boolean_t(0)
        let result = unsafe task_policy_get(
            mach_task_self_, task_policy_flavor_t(Self.categoryPolicy), &role, &count, &getDefault
        )
        return result == KERN_SUCCESS && count == 1 ? role : nil
    }

    /// The two `PRIO_DARWIN_BG` flags of a process.
    public struct DarwinBackground: Sendable, Equatable {
        /// Set by the process on itself (``ProcessRole/apply()``), `PROC_FLAG_DARWINBG`.
        public var internalFlag: Bool
        /// Set by another process by pid (``ProcessRole/applySuppression(toChild:)``) or inherited from a
        /// suppressed parent, `PROC_FLAG_EXT_DARWINBG`.
        public var externalFlag: Bool

        public init(internalFlag: Bool, externalFlag: Bool) {
            self.internalFlag = internalFlag
            self.externalFlag = externalFlag
        }

        /// Whether either flag suppresses the process.
        public var isSuppressed: Bool { internalFlag || externalFlag }
    }

    /// The `PRIO_DARWIN_BG` flags of `pid` (this process by default), from `proc_pidinfo(PROC_PIDTBSDINFO)`;
    /// nil when the read failed.
    public static func darwinBackground(pid: pid_t = getpid()) -> DarwinBackground? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // SAFETY: `info` has room for the `size` bytes the flavor writes, and lives across the call.
        guard unsafe blockingProcPidInfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return DarwinBackground(
            internalFlag: info.pbi_flags & Self.darwinBackgroundFlag != 0,
            externalFlag: info.pbi_flags & Self.externalDarwinBackgroundFlag != 0
        )
    }

    private func setPolicies() throws(ProcessRoleError) {
        let (category, latency, throughput): (integer_t, integer_t, integer_t) = switch self {
        case .foreground: (Self.foregroundApplication, Self.latencyTier0, Self.throughputTier0)
        case .background, .backgroundSuppressed: (Self.backgroundApplication, Self.latencyTier5, Self.throughputTier5)
        }
        var role = category
        let categoryResult = unsafe task_policy_set(mach_task_self_, task_policy_flavor_t(Self.categoryPolicy), &role, 1)
        guard categoryResult == KERN_SUCCESS else { throw .category(categoryResult) }
        // struct task_qos_policy: the latency tier, then the throughput tier.
        var tiers: (integer_t, integer_t) = (latency, throughput)
        let qosResult = unsafe withUnsafeMutablePointer(to: &tiers) { pointer in
            unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: 2) { policy in
                unsafe task_policy_set(mach_task_self_, task_policy_flavor_t(Self.baseQoSPolicy), policy, 2)
            }
        }
        guard qosResult == KERN_SUCCESS else { throw .baseQoS(qosResult) }
    }

    private static func setDarwinBackground(_ on: Bool, pid: id_t) throws(ProcessRoleError) {
        guard setpriority(PRIO_DARWIN_PROCESS, pid, on ? PRIO_DARWIN_BG : 0) == 0 else {
            throw .darwinBackground(errno)
        }
    }

    // mach/task_policy.h and mach/thread_policy.h; the tier macros are `(0xFF << 16) | (tier + 1)` for
    // latency and `(0xFE << 16) | (tier + 1)` for throughput.
    private static let categoryPolicy: Int32 = 1 // TASK_CATEGORY_POLICY
    private static let baseQoSPolicy: Int32 = 8 // TASK_BASE_QOS_POLICY
    private static let foregroundApplication: integer_t = 1 // TASK_FOREGROUND_APPLICATION
    private static let backgroundApplication: integer_t = 2 // TASK_BACKGROUND_APPLICATION
    private static let latencyTier0: integer_t = 0x00FF_0001
    private static let latencyTier5: integer_t = 0x00FF_0006
    private static let throughputTier0: integer_t = 0x00FE_0001
    private static let throughputTier5: integer_t = 0x00FE_0006
    // sys/proc_info.h `pbi_flags` (XNU `proc_get_darwinbgstate`).
    private static let darwinBackgroundFlag: UInt32 = 0x8000 // PROC_FLAG_DARWINBG
    private static let externalDarwinBackgroundFlag: UInt32 = 0x10000 // PROC_FLAG_EXT_DARWINBG
}

/// Why a ``ProcessRole`` change failed; the process keeps the parts applied before the failing call.
public enum ProcessRoleError: Error, Equatable {
    /// `task_policy_set(TASK_CATEGORY_POLICY)` returned this `kern_return_t`.
    case category(Int32)
    /// `task_policy_set(TASK_BASE_QOS_POLICY)` returned this `kern_return_t`.
    case baseQoS(Int32)
    /// `setpriority(PRIO_DARWIN_PROCESS)` failed with this errno.
    case darwinBackground(Int32)
}
