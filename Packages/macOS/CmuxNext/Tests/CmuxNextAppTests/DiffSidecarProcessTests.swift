@testable import CmuxNextApp
import Foundation
import Synchronization
import Testing

/// diff-host S4: one sidecar request per child process, as the classic bridge
/// ran it. The children here are shell scripts that speak the same stdio
/// contract (ready marker on stderr, one request on stdin, one reply on stdout).
@Suite(.serialized)
struct DiffSidecarProcessTests {
    static let marker = "printf 'cmux-diff-sidecar-process-group-ready\\n' >&2"

    /// A script in a fresh folder; `$DIR` in `body` is that folder.
    static func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-diff-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "sidecar.sh")
        try Data("#!/bin/sh\nDIR='\(directory.path)'\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static let fast = DiffSidecarProcess.Limits(startup: .seconds(5), request: .seconds(10), grace: .milliseconds(100))

    @Test(.timeLimit(.minutes(1))) func writesTheRequestAfterTheReadyMarkerAndReturnsTheReply() async throws {
        let sidecar = try Self.script("\(Self.marker)\ncat > \"$DIR/request\"\nprintf '{\"id\":\"1\",\"result\":{\"type\":\"sessionClosed\"}}'")
        // Assert the pipe handshake and bytes, independent of scheduling delays
        // in parallel app tests. The deadline tests below use the real clock.
        let reply = try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data(#"{"method":"x"}"#.utf8),
                                                     limits: Self.fast, clock: ManualClock())
        #expect(String(decoding: reply, as: UTF8.self) == #"{"id":"1","result":{"type":"sessionClosed"}}"#)
        let request = try Data(contentsOf: sidecar.deletingLastPathComponent().appending(path: "request"))
        #expect(String(decoding: request, as: UTF8.self) == #"{"method":"x"}"#)
    }

    @Test func aChildThatNeverReportsItsGroupFailsAtStartup() async throws {
        let sidecar = try Self.script("exec sleep 30")
        var limits = Self.fast
        limits.startup = .milliseconds(300)
        await #expect(throws: DiffSidecarError.startFailed) {
            try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{}".utf8), limits: limits)
        }
    }

    /// The deadline stops the child (the real sidecar's whole process group;
    /// a shell script cannot make one, so this checks the child itself).
    @Test func aMissedDeadlineStopsTheChild() async throws {
        // The pid file is written before the ready marker, so it exists before the deadline starts
        // (a loaded run could otherwise stop the child between the marker and the write).
        let sidecar = try Self.script("echo $$ > \"$DIR/child\"\n\(Self.marker)\nexec sleep 30")
        var limits = Self.fast
        limits.request = .milliseconds(400)
        await #expect(throws: DiffSidecarError.timedOut) {
            try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{}".utf8), limits: limits)
        }
        let pidText = try String(contentsOf: sidecar.deletingLastPathComponent().appending(path: "child"), encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await Self.becomesTrue { kill(pid, 0) != 0 }, "the child survived")
    }

    /// The request deadline runs from the ready marker: a slow start is the
    /// startup limit's to judge. Run 37509955149 timed out a child that had
    /// not yet run its first line, because the request deadline began at launch.
    @Test func theRequestDeadlineStartsAtTheReadyMarker() async throws {
        let sidecar = try Self.script("sleep 1.5\n\(Self.marker)\ncat > /dev/null\nprintf 'ok'")
        var limits = Self.fast
        limits.request = .seconds(1)
        let reply = try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{}".utf8), limits: limits)
        #expect(String(decoding: reply, as: UTF8.self) == "ok")
    }

    @Test func aNonZeroExitIsAFailure() async throws {
        let sidecar = try Self.script("\(Self.marker)\ncat > /dev/null\nprintf 'partial'\nexit 3")
        await #expect(throws: DiffSidecarError.failed(status: 3)) {
            try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{}".utf8), limits: Self.fast)
        }
    }

    @Test func anEmptyReplyIsAFailure() async throws {
        let sidecar = try Self.script("\(Self.marker)\ncat > /dev/null")
        await #expect(throws: DiffSidecarError.failed(status: 0)) {
            try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{}".utf8), limits: Self.fast)
        }
    }

    @Test func cancellingTheCallerStopsTheChild() async throws {
        let sidecar = try Self.script("\(Self.marker)\necho $$ > \"$DIR/pid\"\nexec sleep 30")
        let task = Task { try await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data("{}".utf8), limits: Self.fast) }
        let pidFile = sidecar.deletingLastPathComponent().appending(path: "pid")
        #expect(await Self.becomesTrue { FileManager.default.fileExists(atPath: pidFile.path) })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await Self.becomesTrue { kill(pid, 0) != 0 }, "the child survived")
    }

    static func becomesTrue(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

