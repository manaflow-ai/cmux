public import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``AppChannelDownloading`` backed by a `URLSession` download task.
public struct URLSessionAppChannelDownloader: AppChannelDownloading {
    /// The server answered with a non-success HTTP status.
    public struct HTTPStatusError: Error, Equatable, Sendable {
        /// The HTTP status code.
        public let statusCode: Int
    }

    /// Creates a downloader.
    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

// crash-allow: URLSession serializes callbacks and the lock protects completion racing with cancellation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // lint:allow lock - cancellation and delegate completion share the continuation.
    private let lock = NSLock()
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?
    /// Set when the task completes before the continuation is installed (a cancel that
    /// raced the start), so ``setContinuation(_:)`` can resume it immediately.
    private var completion: Result<Void, any Error>?

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        let early: Result<Void, any Error>? = lock.withLock {
            if let completion { return completion }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        } else {
            progress(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this callback returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLSessionAppChannelDownloader.HTTPStatusError(statusCode: http.statusCode)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result): (CheckedContinuation<Void, any Error>?, Result<Void, any Error>) = lock.withLock {
            let result: Result<Void, any Error>
            if let failure = error ?? moveError {
                result = .failure(failure)
            } else {
                result = .success(())
            }
            completion = result
            let pending = self.continuation
            self.continuation = nil
            return (pending, result)
        }
        continuation?.resume(with: result)
    }
}
