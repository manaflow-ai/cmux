import Darwin

/// A caught signal returns to its default action in every program the
/// process execs; an ignored one stays ignored there.
private let caughtAndDropped: @convention(c) (Int32) -> Void = { _ in }

/// Signal dispositions of the app process that children must not inherit.
///
/// A write to a closed pipe or socket must fail with EPIPE instead of ending
/// the app. Every child the app starts (Foundation `Process`, posix_spawn,
/// crashpad, Chromium helpers, forkpty shells) must still start with
/// default dispositions: an inherited ignored SIGPIPE makes `yes | head`
/// style pipelines in those children spin instead of ending.
///
/// SIGPIPE is therefore caught by a no-op handler instead of `SIG_IGN`: the
/// write still fails with EPIPE, and exec resets the handler to the default
/// in every child, whatever API spawned it (no per-site
/// `POSIX_SPAWN_SETSIGDEF` needed, and Foundation's `Process` offers none).
/// TERM, INT and HUP inherited as ignored from the launcher (nohup, some
/// CI runners) go back to the default, so children and the app's own quit
/// handling see them; `QuitSignal` installs the app's handlers later.
enum ChildSignalDefaults {
    static let restoredSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Call once at launch, before any socket or pipe exists.
    static func installAppSignalPolicy() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = caughtAndDropped
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGPIPE, &action, nil)
        for signal in restoredSignals {
            var current = sigaction()
            sigaction(signal, nil, &current)
            // SIG_IGN is the handler value 1 (<sys/signal.h>).
            if unsafeBitCast(current.__sigaction_u, to: Int.self) == 1 {
                _ = Darwin.signal(signal, SIG_DFL)
            }
        }
    }
}
