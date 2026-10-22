import CmuxNextWakeups
import Foundation
import os

/// One run of the bundled acpmux CLI against this app's daemon (its ``AcpmuxEnvironment``
/// variables), off the caller's thread: output goes to files, the exit arrives through the
/// termination handler, and a deadline ends a run that hangs.
nonisolated struct AcpmuxPeerUpdateCommand: Sendable {
    struct Result: Sendable, Equatable {
        /// The exit status; nil when it did not start or the deadline ended it.
        var status: Int32?
        var output: String
        var errors: String
    }

    var executable: URL
    var environment: [String: String]
    /// A `host update` uploads a binary over ssh and waits for the new daemon: minutes, not hours.
    var deadline: Duration = .seconds(900)

    /// `acpmux --json host update NAME --binary-dir DIR [--if-idle]`. `--if-idle` unless
    /// `whileBusy`: the CLI then leaves a peer mid-turn alone and answers busy. Without it, the
    /// update restarts the peer's daemon mid-turn, and the new daemon resumes what it interrupted.
    static func updateArguments(peer: String, binaryDirectory: URL, whileBusy: Bool) -> [String] {
        let arguments = ["--json", "host", "update", peer, "--binary-dir", binaryDirectory.path]
        return whileBusy ? arguments : arguments + ["--if-idle"]
    }

    func run(_ arguments: [String]) async -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-acpmux-peer-update-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("out"), errorsURL = directory.appendingPathComponent("err")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorsURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL), let errors = try? FileHandle(forWritingTo: errorsURL) else {
            return Result(status: nil, output: "", errors: "no output file")
        }
        defer {
            try? output.close()
            try? errors.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // Files, not pipes: the CLI never blocks on a full pipe, whatever it prints.
        process.standardOutput = output
        process.standardError = errors
        let timer = DemandTimer(owner: "acpmux-peer-update")
        let status: Int32? = await withCheckedContinuation { continuation in
            // carve-out: resumes the continuation once from callback threads; no await under the lock
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Int32?) -> Void = { status in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: status) }
            }
            process.terminationHandler = { finish($0.terminationStatus) }
            do { try process.run() } catch {
                finish(nil)
                return
            }
            timer.schedule(after: deadline) {
                if process.isRunning { process.terminate() }
                finish(nil)
            }
        }
        timer.cancel()
        let text = { (url: URL) in String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self) }
        return Result(status: status, output: text(outputURL), errors: text(errorsURL))
    }
}
