// Safety: the closure is created by the single `arm` owner and invoked only on
// MobileCrashRevocationWatcher's private serial lifecycle queue.
struct CrashLifecycleAction: @unchecked Sendable {
    let body: () -> Void
}
