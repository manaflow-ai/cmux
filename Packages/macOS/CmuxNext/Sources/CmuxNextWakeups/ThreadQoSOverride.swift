import Darwin
import Dispatch

/// Starts and ends a QoS override of one thread: how a ``WorkHandle/raise(to:)`` boosts a lane item that already
/// runs. Chrome's `PlatformThreadApple::SetThreadTypeOverride` and `RemoveThreadTypeOverride`
/// (base/threading/platform_thread_apple.mm), used by `ScopedBoostablePriority`
/// (base/threading/scoped_thread_priority.h). ``system`` is the kernel's; tests pass one that counts calls.
struct ThreadQoSOverride: Sendable {
    /// One started override, ended with ``end``.
    struct Token: Sendable, Equatable {
        /// The `pthread_override_t`'s address (``system``) or a test's count.
        let raw: UInt
    }

    /// Starts an override of `thread` (a Mach port, from `pthread_mach_thread_np`) at `priority`'s QoS; nil when
    /// there is no such thread or the kernel refused it. The thread must be alive: a lane starts it on the item's
    /// own thread, or under the lane's lock while the target thread runs the item.
    let start: @Sendable (_ thread: mach_port_t, _ priority: WorkPriority) -> Token?
    /// Ends the override `token` names; called once per token.
    let end: @Sendable (_ token: Token) -> Void

    /// `pthread_override_qos_class_start_np` and `pthread_override_qos_class_end_np` (pthread/qos.h). The end
    /// may run on any thread; lanes end it on the item's own thread when the item finishes.
    static let system = ThreadQoSOverride(
        start: { thread, priority in
            guard let pthread = pthread_from_mach_thread_np(thread) else { return nil }
            let raw = UInt(bitPattern: pthread_override_qos_class_start_np(pthread, priority.qos.qosClass.rawValue, 0))
            return raw == 0 ? nil : Token(raw: raw)
        },
        end: { token in
            guard let override = OpaquePointer(bitPattern: token.raw) else { return }
            _ = pthread_override_qos_class_end_np(override)
        })
}
