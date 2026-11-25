import CmuxNextCompat
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
import os

/// Reads this Mac's share status from `cmux rd share-status`, a fresh process each time: the Rust
/// contract every host uses (ready, needs_screen_recording, needs_accessibility, capture_failed, and
/// the sentence a viewer shows). A fresh process reads a grant the person made in System Settings a
/// moment ago, which this long-running app's own preflight may not; nothing here decides a state.
nonisolated struct MacScreenShareStatusProbe: Sendable {
    /// The name viewers list this Mac by.
    var host: String
    /// The app System Settings lists the grants under.
    var grantee: String
    /// How long one probe may take (one small capture and its first frame, about 2 s at most).
    var deadline: Duration = .seconds(6)
    /// The bundled cmux; tests replace it.
    var binary: @Sendable () -> URL? = { MacScreenRdProcess.binary }

    /// The most stdout kept from one probe.
    private static let outputCap = 65_536
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-share-status")

    /// The status for a session of `scope` (`view` or `control`); with `frame`, one picture is looked
    /// at too. Nil when the probe could not run or answer (an older cmux without the command): the
    /// caller then serves as before.
    func read(scope: String, frame: Bool) async -> ScreenShareStatus? {
        guard let binary = binary() else { return nil }
        let arguments = ["rd", "share-status", "--scope", scope, "--frame", frame ? "yes" : "no",
                         "--host", host, "--grantee", grantee]
        let output = await Self.run(binary, arguments, deadline: deadline)
        guard let output, let status = Self.decode(output) else {
            Self.logger.error("share-status gave no answer")
            return nil
        }
        Self.logger.info("share-status \(status.state, privacy: .public)")
        return status
    }

    /// The status from the probe's JSON line (`{"state":..,"message":..}`).
    static func decode(_ data: Data) -> ScreenShareStatus? {
        struct Line: Decodable {
            var state: String
            var message: String
        }
        let line = data.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? data
        guard let decoded = try? JSONDecoder().decode(Line.self, from: line) else { return nil }
        return ScreenShareStatus(state: decoded.state, message: decoded.message)
    }

    /// Runs the probe and gives its stdout once it exits; nil when it failed to start, exited non-zero
    /// or ran past `deadline` (then it is ended). Never blocks the caller's thread.
    @concurrent private static func run(_ binary: URL, _ arguments: [String], deadline: Duration) async -> Data? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let collected = Mutex(Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.blockingAvailableData()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                // One short JSON line is the answer: a runaway process never grows this past the cap.
                collected.withLock { if $0.count < Self.outputCap { $0.append(data.prefix(Self.outputCap - $0.count)) } }
            }
        }
        let finished = Mutex<CheckedContinuation<Data?, Never>?>(nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            finished.withLock { $0 = continuation }
            let resume: @Sendable (Data?) -> Void = { value in
                finished.withLock { pending in
                    pending?.resume(returning: value)
                    pending = nil
                }
            }
            process.terminationHandler = { ended in
                // The pipe's last bytes may land after the exit: read what is left before answering.
                stdout.fileHandleForReading.readabilityHandler = nil
                // concurrency-allow: terminationHandler runs on a Foundation queue, never main; the pipe is at EOF.
                let rest = (try? stdout.fileHandleForReading.blockingReadToEnd()) ?? nil
                let data = collected.withLock { data -> Data in
                    if let rest, data.count < Self.outputCap { data.append(rest.prefix(Self.outputCap - data.count)) }
                    return data
                }
                resume(ended.terminationStatus == 0 ? data : nil)
            }
            do { try process.run() } catch {
                resume(nil)
                return
            }
            // The probe's deadline: it ends the process, whose termination answers. The timer lives
            // until the process ends (its termination handler holds and cancels it).
            let timer = DemandTimer(owner: "mac-screen.share-status-deadline")
            timer.schedule(after: deadline) {
                if process.isRunning { process.terminate() }
            }
            let answer = process.terminationHandler
            process.terminationHandler = { ended in
                timer.cancel()
                answer?(ended)
            }
        }
    }
}
