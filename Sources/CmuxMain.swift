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
        crashOnExceptionsEscapingToTheRunLoop()
        FileDescriptorLimitController().raiseSoftLimitIfNeeded()
        AppHostProcessReceipt.writeIfRequired()
#if DEBUG
        // Bonsplit's `dlog` and the app's `cmuxDebugLog` resolve the same
        // debug log file. Route bonsplit through the shared writer so the
        // file has exactly one serialized append path (single O_APPEND
        // handle, monotonic #<seq> line prefixes); with two independent
        // appenders, concurrent lines interleaved and landed out of order.
        Bonsplit.DebugEventLog.setExternalSink { cmuxDebugLog($0) }
#endif
        CmuxWorkerEntrypoint(arguments: CommandLine.arguments).runIfRequested()
        SurfaceResumeApprovalStore.preloadSigningSecret()
        cmuxApp.main()
    }

    /// Makes an Objective-C exception that reaches `-[NSApplication run]`
    /// terminate the process at the throw instead of being logged and swallowed.
    ///
    /// AppKit's run loop catches such exceptions by default and keeps running.
    /// When the exception unwinds through a Swift concurrency job (a
    /// `@MainActor` `Task` body, for example), the runtime skips restoring its thread-local
    /// executor tracking, which is left pointing at the dead job's stack frame.
    /// The next main-actor isolation check on that thread (`assumeIsolated`,
    /// SwiftUI, or WebKit's own Swift code during a layer-tree commit) reads
    /// that garbage and crashes far from the cause, which is how
    /// CMUXTERM-MACOS-1C1Z and CMUXTERM-MACOS-3YQ6 present. Failing at the
    /// throw gives a report with the real exception, and with Sentry's
    /// `enableUncaughtNSExceptionReporting` the reason and throw stack too.
    ///
    /// `register(defaults:)` only seeds the registration domain, so a user or
    /// test override of `NSApplicationCrashOnExceptions` still wins.
    private static func crashOnExceptionsEscapingToTheRunLoop() {
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
    }
}
