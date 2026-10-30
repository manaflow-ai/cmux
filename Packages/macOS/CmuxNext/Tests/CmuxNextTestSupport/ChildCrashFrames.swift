import Darwin
import Foundation
public import Testing

/// The frames of a crash in an exit test's child process, so a test that proves "this traps no more" fails
/// with its own assertion and the trapping frame, instead of killing the whole test process. It only
/// reports a crash: the handler exits with 128 plus the signal, so a caught trap still fails
/// `processExitsWith: .success`. The child asserts the exact result it expects (``fail(_:)`` otherwise).
///
/// A trap in the test process ends every test still running (the swift test job then waits on the crashed
/// process and stops with "no test finished in 300s", issue #28492), and a fleet step prints no Swift
/// backtrace. In the child, ``printOnFatalSignal()`` replaces the runtime's handlers: a fatal signal writes
/// the crashing thread's frames to standard error and exits with 128 plus the signal. The parent observes
/// standard error and ``record(_:)`` puts those frames in its failure.
///
/// ```swift
/// let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
///     ChildCrashFrames.printOnFatalSignal()
///     // the call that must not trap
/// }
/// ChildCrashFrames.record(result)
/// ```
public nonisolated enum ChildCrashFrames {
    /// The signals a trap, a bad access or an abort raise.
    static let fatalSignals: [Int32] = [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT]

    /// Call first in an exit test's body: from then on a fatal signal in the child writes its frames.
    public static func printOnFatalSignal() {
        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = writeFramesAndExit
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signal, &action, nil)
        }
    }

    /// Ends the child with a failure and says why on standard error: the parent's ``record(_:)`` shows it.
    public static func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data("exit test child failed: \(why)\n".utf8))
        exit(EXIT_FAILURE)
    }

    /// Records the child's standard error as an issue when the child did not exit with success, so the
    /// failure names the frames. Nothing when it succeeded (or never ran: `#expect` already failed).
    public static func record(_ result: ExitTest.Result?, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let result else { return }
        if case .exitCode(EXIT_SUCCESS) = result.exitStatus { return }
        let text = String(decoding: result.standardErrorContent, as: UTF8.self)
        Issue.record("the child ended with \(result.exitStatus); its standard error:\n\(text)", sourceLocation: sourceLocation)
    }
}

/// Room for the frames, made before any signal: the handler must not allocate.
nonisolated(unsafe) private let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

/// The fatal-signal handler: async-signal-safe calls only (write, backtrace, backtrace_symbols_fd, _exit).
nonisolated(unsafe) private let writeFramesAndExit: @convention(c) (Int32) -> Void = { signal in
    let header: StaticString = "*** exit test child: fatal signal; the crashing thread's frames:\n"
    _ = write(STDERR_FILENO, header.utf8Start, header.utf8CodeUnitCount)
    let count = backtrace(frameBuffer, 128)
    backtrace_symbols_fd(frameBuffer, count, STDERR_FILENO)
    _exit(128 + signal)
}
