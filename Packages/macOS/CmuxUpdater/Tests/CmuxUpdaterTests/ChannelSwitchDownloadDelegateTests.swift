import CmuxSafeConcurrency
import Foundation
import Testing
@testable import CmuxUpdater

/// The channel-switch download delegate keeps its continuation, move error and early completion in
/// one `Mutex<State>`, so it is plainly `Sendable`. These drive each state
/// transition through the URLSession delegate entry points with an unresumed task. The time limit
/// turns a lost resume (a continuation kept in `State` but never taken) into a failure, not a hang.
@Suite(.timeLimit(.minutes(1))) struct ChannelSwitchDownloadDelegateTests {
    private struct Probe: Error, Equatable {}

    /// A task that is never resumed: only its identity reaches the delegate.
    private static func makeTask() -> URLSessionDownloadTask {
        URLSession.shared.downloadTask(with: URL(fileURLWithPath: "/nonexistent/app.zip"))
    }

    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelSwitchDownloadDelegateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func completionBeforeTheContinuationResumesItAtOnce() async throws {
        let task = Self.makeTask()
        defer { task.cancel() }
        let delegate = DownloadDelegate(destination: URL(fileURLWithPath: "/nonexistent"), progress: { _ in })
        delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: Probe())

        await #expect(throws: Probe.self) {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                delegate.setContinuation(continuation)
            }
        }
    }

    @Test func movedDownloadCompletesTheInstalledContinuation() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("download.tmp")
        let destination = directory.appendingPathComponent("app.zip")
        try Data("payload".utf8).write(to: location)
        let task = Self.makeTask()
        defer { task.cancel() }
        let delegate = DownloadDelegate(destination: destination, progress: { _ in })

        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
            delegate.setContinuation(continuation)
            delegate.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: location)
            delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
        }

        #expect(try Data(contentsOf: destination) == Data("payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }

    @Test func failedMoveFailsTheDownloadEvenWithoutATransportError() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Self.makeTask()
        defer { task.cancel() }
        let delegate = DownloadDelegate(destination: directory.appendingPathComponent("app.zip"), progress: { _ in })

        await #expect(throws: (any Error).self) {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                delegate.setContinuation(continuation)
                delegate.urlSession(
                    URLSession.shared,
                    downloadTask: task,
                    didFinishDownloadingTo: directory.appendingPathComponent("missing.tmp")
                )
                delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
            }
        }
    }

    @Test func concurrentCompletionAndInstallResumeExactlyOnce() async throws {
        for _ in 0..<64 {
            let delegate = DownloadDelegate(destination: URL(fileURLWithPath: "/nonexistent"), progress: { _ in })
            let completer = Task.detached {
                let task = Self.makeTask()
                delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
                task.cancel()
            }
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                delegate.setContinuation(continuation)
            }
            await completer.value
        }
    }
}
