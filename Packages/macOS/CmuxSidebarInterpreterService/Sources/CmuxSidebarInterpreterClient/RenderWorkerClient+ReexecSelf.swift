import Foundation

public extension RenderWorkerClient {
    /// The argv flag that puts a host binary into sidebar **render** worker
    /// mode. The app's entry point checks for this *before* any of the app's
    /// own AppKit/SwiftUI setup and runs the faceless render-worker loop
    /// instead of the app.
    static let workerModeArgument = "--cmux-sidebar-render-worker"

    /// A client that runs the render worker by re-executing the current
    /// process's binary with ``workerModeArgument``.
    ///
    /// Same re-exec-self model as
    /// ``InterpreterClient/reexecingCurrentBinary(timeout:)``: no separate
    /// helper to bundle and sign, and the worker always matches the host's
    /// interpreter/renderer version.
    ///
    /// - Parameters:
    ///   - sourceKey: Optional owner-defined key for cache/substitution checks.
    ///   - ackTimeout: Deadline for a scene ack before the worker is treated as
    ///     hung and discarded.
    static func reexecingCurrentBinary(
        sourceKey: String? = nil,
        ackTimeout: Duration = .seconds(3)
    ) -> RenderWorkerClient {
        let binary = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return RenderWorkerClient(
            executableURL: binary,
            arguments: [workerModeArgument],
            sourceKey: sourceKey,
            ackTimeout: ackTimeout
        )
    }
}
