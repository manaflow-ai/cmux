public import Foundation
import CmuxNextWakeups

/// Lists and extracts a pack with the system `tar` (bsdtar: it reads xz and
/// refuses absolute paths and `..` by itself; the installer checks again).
///
/// Each run goes through ``AsyncProcess``: the spawn never runs on the caller's
/// thread or actor, tar runs at the caller's priority's `processQoS`, and its
/// output is read without holding a thread, so a long listing never stalls it.
public struct TarChromiumRuntimeUnpacker: ChromiumRuntimeUnpacking {
    /// The tar executable.
    public var tool: URL
    private let processes: AsyncProcess

    /// Creates an unpacker.
    ///
    /// - Parameters:
    ///   - tool: The tar to run; `/usr/bin/tar` by default.
    ///   - processes: Runs it; tests pass one on a manual clock.
    public init(tool: URL = URL(filePath: "/usr/bin/tar"), processes: AsyncProcess = AsyncProcess()) {
        self.tool = tool
        self.processes = processes
    }

    public func entries(of archive: URL) async throws(ChromiumRuntimeInstallError) -> [String] {
        let output = try await run(["-tf", archive.path], onCancel: .stop)
        return output.split(separator: "\n").map(String.init)
    }

    /// A cancel lets tar finish, so the installer never removes `directory` while tar still writes into it.
    public func unpack(_ archive: URL, into directory: URL) async throws(ChromiumRuntimeInstallError) {
        _ = try await run(["-xf", archive.path, "-C", directory.path, "--no-same-owner"], onCancel: .finish)
    }

    /// Runs tar with `arguments`; its standard output and error share one pipe, as one message.
    private func run(_ arguments: [String],
                     onCancel: ProcessRequest.CancelBehavior) async throws(ChromiumRuntimeInstallError) -> String {
        let outcome: ProcessOutcome
        do {
            outcome = try await processes.run(ProcessRequest(tool, arguments, errorOutput: .merge, onCancel: onCancel))
        } catch ProcessFailure.launch(let message) {
            throw .unpack(message)
        } catch {
            throw .unpack(error.localizedDescription)
        }
        guard outcome.succeeded else { throw .unpack(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return outcome.text
    }
}
