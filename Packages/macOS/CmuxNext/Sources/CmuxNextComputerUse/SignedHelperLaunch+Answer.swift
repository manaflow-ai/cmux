// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
public import Foundation

extension SignedHelperLaunch {
    /// Why a short helper command gave no answer, for the caller's log.
    public enum AnswerFailure: Error, Equatable, Sendable {
        case notStarted(String)
        case noAnswer
    }

    /// Runs one short command of the staged helper `executable` (responsibility disclaimed) and
    /// decodes its one JSON line. Its stdin and stderr are /dev/null. Bounded: a helper that does
    /// not answer within `timeout` is ended and reads as no answer. Off the caller's actor.
    @concurrent public static func answer<Answer: Decodable & Sendable>(
        executable: URL, arguments: [String], as _: Answer.Type,
        timeout: Duration = .seconds(10), clock: any Clock<Duration> = ContinuousClock()
    ) async -> Result<Answer, AnswerFailure> {
        guard let null = FileHandle(forUpdatingAtPath: "/dev/null") else { return .failure(.notStarted("no /dev/null")) }
        defer { try? null.close() }
        let stdout = Pipe()
        let pid: pid_t
        do {
            pid = try spawn(executable: executable, arguments: arguments, stdin: null.fileDescriptor,
                            stdout: stdout.fileHandleForWriting.fileDescriptor, stderr: null.fileDescriptor)
        } catch {
            return .failure(.notStarted(String(describing: error)))
        }
        try? stdout.fileHandleForWriting.close()
        let reader = stdout.fileHandleForReading
        // The kill and the reap take turns on `gate`, so the kill never reaches a reused pid.
        let gate = ReapGate(pid: pid)
        let deadline = DemandTimer(owner: "signed-helper.answer-deadline", clock: clock)
        deadline.schedule(after: timeout) {
            gate.kill()
        }
        // @concurrent, never the main actor: one short JSON line, then EOF.
        let data = (try? reader.blockingReadToEnd()) ?? nil
        deadline.cancel()
        gate.close()
        try? reader.close()
        var status: Int32 = 0
        // concurrency-allow: @concurrent; the helper closed its stdout, so it is exiting now.
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        guard let line = data?.split(separator: UInt8(ascii: "\n")).first,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(line)) else { return .failure(.noAnswer) }
        return .success(answer)
    }
}

/// A deadline's SIGKILL for a helper that is not reaped yet: ``kill()`` does nothing once
/// ``close()`` ran (before the reap), so it never reaches a pid the system has handed on.
private nonisolated final class ReapGate: Sendable {
    private let pid: pid_t
    private let reaped = Mutex(false)

    init(pid: pid_t) {
        self.pid = pid
    }

    func kill() {
        reaped.withLock { if !$0 { _ = Darwin.kill(pid, SIGKILL) } }
    }

    func close() {
        reaped.withLock { $0 = true }
    }
}
