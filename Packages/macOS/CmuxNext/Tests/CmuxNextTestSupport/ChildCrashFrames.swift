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
/// backtrace. In the child, ``printOnFatalSignal(_:)`` replaces the runtime's handlers: a fatal signal writes
/// the crashing thread's frames to standard error and to a file named by the test and the parent's pid, then
/// exits with 128 plus the signal. `#expect(processExitsWith:)` returns nil when it fails, so the parent reads
/// that file, not the child's standard error: ``record(_:)`` runs after the expectation in every case and puts
/// the frames in the failure.
///
/// ```swift
/// await #expect(processExitsWith: .success) {
///     ChildCrashFrames.printOnFatalSignal("aSocketPathPastTheUnixLimit")
///     // the call that must not trap
/// }
/// ChildCrashFrames.record("aSocketPathPastTheUnixLimit")
/// ```
public nonisolated enum ChildCrashFrames {
    /// The signals a trap, a bad access or an abort raise.
    static let fatalSignals: [Int32] = [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT]

    /// The frames file of exit test `name` whose parent test process is `parent`.
    static func path(_ name: String, parent: pid_t) -> String {
        NSTemporaryDirectory() + "cmux-exit-child-\(parent)-\(name).frames"
    }

    /// Call first in an exit test's body: from then on a fatal signal in the child writes its frames.
    /// `name` is the same text the parent passes to ``record(_:)``.
    public static func printOnFatalSignal(_ name: String) {
        let file = path(name, parent: getppid())
        unlink(file)
        framesPath = strdup(file)
        // A Swift global is made at its first use: touch the buffer here, so the handler never allocates
        // (a malloc inside a handler can deadlock when the signal came from inside malloc).
        frameBuffer.initialize(repeating: nil, count: Int(frameCapacity))
        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = writeFramesAndExit
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signal, &action, nil)
        }
    }

    /// Ends the child with a failure and says why: the parent's ``record(_:)`` shows it.
    public static func fail(_ why: String) -> Never {
        let line = "exit test child failed: \(why)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let framesPath { FileManager.default.createFile(atPath: String(cString: framesPath), contents: Data(line.utf8)) }
        exit(EXIT_FAILURE)
    }

    /// In the parent, after the exit test: records what the child of exit test `name` wrote (its crash frames,
    /// or why it failed) as an issue, and removes the file. Nothing when the child wrote nothing.
    public static func record(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let file = path(name, parent: getpid())
        guard let data = FileManager.default.contents(atPath: file) else { return }
        unlink(file)
        Issue.record("the exit test child wrote:\n\(String(decoding: data, as: UTF8.self))", sourceLocation: sourceLocation)
    }
}

/// The child's frames file, set before any signal: the handler must not allocate.
nonisolated(unsafe) private var framesPath: UnsafeMutablePointer<CChar>?

/// The most frames the handler writes.
nonisolated private let frameCapacity: Int32 = 128

/// Room for the frames, made by ``ChildCrashFrames/printOnFatalSignal(_:)`` before any handler is set: the handler
/// must not allocate.
nonisolated(unsafe) private let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(frameCapacity))

/// The fatal-signal handler: async-signal-safe calls only (write, open, backtrace, backtrace_symbols_fd, _exit).
nonisolated(unsafe) private let writeFramesAndExit: @convention(c) (Int32) -> Void = { signal in
    let header: StaticString = "*** exit test child: fatal signal; the crashing thread's frames:\n"
    let count = backtrace(frameBuffer, frameCapacity)
    _ = write(STDERR_FILENO, header.utf8Start, header.utf8CodeUnitCount)
    backtrace_symbols_fd(frameBuffer, count, STDERR_FILENO)
    if let framesPath {
        let fd = open(framesPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            _ = write(fd, header.utf8Start, header.utf8CodeUnitCount)
            backtrace_symbols_fd(frameBuffer, count, fd)
            close(fd)
        }
    }
    _exit(128 + signal)
}
