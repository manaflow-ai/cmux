import AppKit

/// The shared terminate request used by the quit shortcut path (keyboard
/// Cmd+Q routing, socket-driven `simulate_shortcut`, and the quit
/// confirmation alert reply).
///
/// `NSApp.terminate` must not run while the main dispatch queue is inside a
/// caller's block. When `applicationShouldTerminate` returns
/// `.terminateLater`, AppKit spins the run loop waiting for
/// `replyToApplicationShouldTerminate`, and the deferred `@MainActor`
/// cleanup task can only start once the main queue is free again. A debug
/// socket command executes inside `v2MainSync` (`DispatchQueue.main.sync`),
/// so terminating synchronously from it deadlocked the app
/// (https://github.com/manaflow-ai/cmux/issues/10788). Scheduling the
/// terminate as a main-run-loop callout lets the handler finish its reply
/// and release the main queue first, matching how a real keyboard Cmd+Q
/// arrives (a run-loop event callout with an idle main queue).
@MainActor
enum AppTerminationRequest {
    /// Requests app termination from a later main-run-loop callout.
    /// `terminate` is injectable for tests; production callers use the
    /// default `NSApp.terminate`.
    static func schedule(
        _ terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                terminate()
            }
        }
    }
}
