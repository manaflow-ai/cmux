import Darwin

/// Signal dispositions of the app process that children must not inherit.
///
/// A write to a closed pipe or socket must fail with EPIPE instead of ending
/// the app. Every child the app starts (Foundation `Process`, posix_spawn,
/// crashpad, Chromium helpers, forkpty shells) must still start with
/// default dispositions: an inherited ignored SIGPIPE makes `yes | head`
/// style pipelines in those children spin instead of ending.
enum ChildSignalDefaults {
    /// Call once at launch, before any socket or pipe exists.
    static func installAppSignalPolicy() {
        _ = signal(SIGPIPE, SIG_IGN)
    }
}
