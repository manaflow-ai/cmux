import Foundation

public extension InterpreterClient {
    /// The argv flag that puts a host binary into sidebar-interpreter worker
    /// mode. The app's entry point checks for this *before* any AppKit/SwiftUI
    /// setup, runs ``runSidebarInterpreterWorker()``, and exits.
    static let workerModeArgument = "--cmux-sidebar-interpreter-worker"

    /// A client that runs the worker by re-executing the current process's
    /// binary with ``workerModeArgument``.
    ///
    /// This avoids bundling and signing a separate helper executable: the app
    /// already contains the interpreter, so the worker is just the same binary
    /// launched in worker mode. The worker process is spawned lazily on the
    /// first render and reused for the session.
    ///
    /// - Parameter timeout: Per-render deadline before the worker is killed and
    ///   the render returns `nil`.
    static func reexecingCurrentBinary(timeout: Duration = .seconds(2)) -> InterpreterClient {
        let binary = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return InterpreterClient(
            executableURL: binary,
            arguments: [workerModeArgument],
            timeout: timeout
        )
    }
}
