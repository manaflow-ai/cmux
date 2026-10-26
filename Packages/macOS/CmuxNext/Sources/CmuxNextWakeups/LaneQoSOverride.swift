import Darwin

/// Raises the thread of a running lane item to `QOS_CLASS_USER_INITIATED` until the item ends.
///
/// Chrome boosts a running thread with `pthread_override_qos_class_start_np` and ends the boost with
/// `pthread_override_qos_class_end_np` (`SetCurrentThreadTypeOverride`, base/threading/platform_thread_apple.mm).
/// ``LaneScheduler`` uses it when shutdown starts while a block-shutdown item runs below
/// ``WorkPriority/userBlocking``: quit waits for that item, so it must not wait behind other work at its
/// old QoS. ``system`` makes the kernel calls; tests pass their own to count them.
struct LaneQoSOverride: Sendable {
    /// Starts an override of `thread`, which runs the item now; returns the call that ends it, or nil when
    /// the kernel refused. The scheduler calls the end on that thread, after the item, once.
    let start: @Sendable (_ thread: pthread_t) -> (@Sendable () -> Void)?

    /// The kernel's override, at `QOS_CLASS_USER_INITIATED` (``WorkPriority/userBlocking``'s QoS).
    static let system = LaneQoSOverride { thread in
        let token: OpaquePointer? = pthread_override_qos_class_start_np(thread, QOS_CLASS_USER_INITIATED, 0)
        // The token travels as its address: OpaquePointer is not Sendable, and only this end call uses it.
        let address = UInt(bitPattern: token)
        guard address != 0 else { return nil }
        return {
            guard let token = OpaquePointer(bitPattern: address) else { return }
            _ = pthread_override_qos_class_end_np(token)
        }
    }
}
