import Darwin

/// The role the kernel gave this process when a hang was sampled (`task_policy_get`
/// `TASK_CATEGORY_POLICY`): AppKit sets foreground while the app is frontmost and background
/// otherwise, and a background app is the one App Nap and a loaded Mac's scheduler hold back. So
/// a main thread off-CPU for seconds in the background may have been napping, not starved
/// (goal field-hang-seconds-tenth). Darwin only: the watchdog thread reads it with one syscall.
public enum TaskRole: String, Sendable, Equatable {
    case foreground
    case background
    /// Darwin background: the lowest CPU and I/O priority.
    case darwinBackground = "darwin-background"
    case other

    /// This process's role now; nil when `task_policy_get` fails.
    public static func current() -> TaskRole? {
        var policy = task_category_policy_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_category_policy_data_t>.size / MemoryLayout<integer_t>.size)
        var getDefault: boolean_t = 0
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) {
                task_policy_get(mach_task_self_, task_policy_flavor_t(TASK_CATEGORY_POLICY), $0, &count, &getDefault)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return TaskRole(role: policy.role)
    }

    init(role: task_role_t) {
        switch role {
        case TASK_FOREGROUND_APPLICATION: self = .foreground
        case TASK_BACKGROUND_APPLICATION: self = .background
        case TASK_DARWINBG_APPLICATION: self = .darwinBackground
        default: self = .other
        }
    }

    /// `app role: background (not frontmost: App Nap and the scheduler may hold it back)`.
    public var line: String {
        switch self {
        case .foreground: "app role: foreground (frontmost)"
        case .background: "app role: background (not frontmost: App Nap and the scheduler may hold it back)"
        case .darwinBackground: "app role: darwin-background (lowest CPU and I/O priority)"
        case .other: "app role: other"
        }
    }
}
