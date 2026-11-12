import Bonsplit
import CmuxFoundation
import Foundation
import SwiftUI

/// The process entry point. When the binary is launched with a worker flag
/// (the app re-executes its own binary so a crash or hang in paste preparation,
/// the Simulator, interpreter, or renderer kills only the worker process), run
/// that worker instead of the app:
/// - the paste worker resolves providers and prepares images before any app or
///   SwiftUI startup;
/// - the Simulator worker owns private frameworks and remote display state;
/// - the render worker hosts its own faceless AppKit session and shares the
///   rendered layer tree with the host;
/// - the interpreter worker (stage-1 fallback path) runs before any
///   AppKit/SwiftUI setup.
@main
enum CmuxMain {
    /// Raises inherited descriptor limits before receipt writing or worker routing.
    static func main() {
        // First: nothing may read preferences before an app-host test process
        // switches to its own domain.
        TestProcessDefaults.installIfHostingTests()
        runStartup()
    }

    /// Runs the ordered startup steps shared by the process entry point and its
    /// startup-order regression test.
    static func runStartup(
        defaults: UserDefaults = .standard,
        raiseFileDescriptorLimit: () -> Void = {
            FileDescriptorLimitController().raiseSoftLimitIfNeeded()
        },
        writeAppHostReceipt: () -> Void = {
            AppHostProcessReceipt.writeIfRequired()
        },
        routeWorkers: () -> Void = {
            CmuxWorkerEntrypoint(arguments: CommandLine.arguments).runIfRequested()
        },
        preloadSigningSecret: () -> Void = {
            SurfaceResumeApprovalStore.preloadSigningSecret()
        },
        launchApp: () -> Void = {
            cmuxApp.main()
        }
    ) {
        installCrashOnExceptionsPolicy(defaults: defaults)
        raiseFileDescriptorLimit()
        writeAppHostReceipt()
#if DEBUG
        // Bonsplit's `dlog` and the app's `cmuxDebugLog` resolve the same
        // debug log file. Route bonsplit through the shared writer so the
        // file has exactly one serialized append path (single O_APPEND
        // handle, monotonic #<seq> line prefixes); with two independent
        // appenders, concurrent lines interleaved and landed out of order.
        Bonsplit.DebugEventLog.setExternalSink { cmuxDebugLog($0) }
#endif
        routeWorkers()
        preloadSigningSecret()
        launchApp()
    }

    /// Installs the AppKit policy that makes exceptions escaping the run loop fatal.
    static func installCrashOnExceptionsPolicy(defaults: UserDefaults = .standard) {
        // AppKit catches exceptions at the run-loop boundary by default. If one
        // unwinds through a Swift concurrency job, that leaves the runtime's
        // thread-local executor tracking pointing at the dead job's stack frame.
        // The next main-actor check then crashes far from the original throw.
        // Registering the default makes AppKit terminate at the throw instead.
        // `register(defaults:)` preserves an explicit user or test override.
        defaults.register(defaults: ["NSApplicationCrashOnExceptions": true])
    }
}
