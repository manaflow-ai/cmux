public import Foundation
import CmuxNextWakeups

/// Lists and extracts a pack with the system `tar` (bsdtar: it reads xz and
/// refuses absolute paths and `..` by itself; the installer checks again).
///
/// Each run goes through ``AsyncProcess``: the spawn never runs on the caller's
/// thread or actor, tar runs at the caller's priority's `processQoS`, and its
/// output is read without holding a thread, so a long listing never stalls it.
/// tar always runs to its end: the installer sees a cancel through its own
/// cancellation checks, never as an unpack failure, and never removes a folder
/// while tar still writes into it.
public struct TarChromiumRuntimeUnpacker: ChromiumRuntimeUnpacking {
    /// The tar executable.
    public var tool: URL
    /// Called with tar's pid on the thread that spawned it (tests check that thread).
    private let onLaunch: (@Sendable (Int32) -> Void)?

    /// Creates an unpacker.
    ///
    /// - Parameter tool: The tar to run; `/usr/bin/tar` by default.
    public init(tool: URL = URL(filePath: "/usr/bin/tar")) {
        self.init(tool: tool, onLaunch: nil)
    }

    /// Creates an unpacker that reports each spawn to `onLaunch` (tests).
    init(tool: URL, onLaunch: (@Sendable (Int32) -> Void)?) {
        self.tool = tool
        self.onLaunch = onLaunch
    }

    public func entries(of archive: URL) async throws(ChromiumRuntimeInstallError) -> [String] {
        let output = try await run(["-tf", archive.path])
        return output.split(separator: "\n").map(String.init)
    }

    public func unpack(_ archive: URL, into directory: URL) async throws(ChromiumRuntimeInstallError) {
        _ = try await run(["-xf", archive.path, "-C", directory.path, "--no-same-owner"])
    }

    /// Runs tar with `arguments` to its end; its standard output and error share one pipe, as one message.
    private func run(_ arguments: [String]) async throws(ChromiumRuntimeInstallError) -> String {
        let request = ProcessRequest(tool, arguments, errorOutput: .merge, onCancel: .finish, onLaunch: onLaunch)
        let outcome: ProcessOutcome
        do {
            outcome = try await AsyncProcess().run(request)
        } catch ProcessFailure.launch(let message) {
            throw .unpack(message)
        } catch {
            // A `.finish` run with no timeout throws only for its launch.
            throw .unpack(error.localizedDescription)
        }
        guard outcome.succeeded else { throw .unpack(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return outcome.text
    }
}
