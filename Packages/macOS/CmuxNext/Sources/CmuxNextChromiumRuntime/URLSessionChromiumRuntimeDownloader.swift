public import Foundation

/// Downloads a pack with `URLSession`, appending to a partial file with a
/// `Range` request when one exists.
///
/// Each download uses its own ephemeral session (no shared cookies or cache);
/// the body streams to disk chunk by chunk, never into memory whole.
public struct URLSessionChromiumRuntimeDownloader: ChromiumRuntimeDownloading {
    /// Seconds without any data before the transfer fails (it then resumes
    /// on the next attempt).
    public var idleTimeout: TimeInterval

    /// Creates a downloader.
    ///
    /// - Parameter idleTimeout: Seconds of silence before an attempt fails; 60 by default.
    public init(idleTimeout: TimeInterval = 60) {
        self.idleTimeout = idleTimeout
    }

    public func download(_ url: URL, to file: URL, expectedSize: Int64,
                         progress: @escaping @Sendable (Int64) -> Void) async throws(ChromiumRuntimeInstallError) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: file.path), !fileManager.createFile(atPath: file.path, contents: nil) {
            throw .filesystem("cannot create \(file.lastPathComponent)")
        }
        let existing = ChromiumRuntimeInstaller.size(of: file)
        if existing >= expectedSize { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: file) } catch { throw .filesystem(error.localizedDescription) }
        defer { try? handle.close() }
        // One delegate callback at a time: the delegate's file writes need no lock.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let delegate = DownloadFileDelegate(handle: handle, existing: existing, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let outcome: DownloadFileDelegate.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.finish = { continuation.resume(returning: $0) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        switch outcome {
        case .complete, .alreadyWhole: return
        case .failed(let error): throw error
        }
    }
}

/// Writes one data task's body to the partial file as it arrives, so nothing
/// is buffered in memory, and reports the outcome once.
// URLSession calls a task's delegate methods one at a time on the serial
// delegate queue: `handle`, `written` and `failure` change only there, and
// `finish` is set before `resume()`.
private final class DownloadFileDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable { // crash-allow: state changes only on the serial delegate queue (see above)
    enum Outcome: Sendable {
        case complete
        /// 416: the partial file is already whole (or longer); the installer's
        /// size and hash checks decide.
        case alreadyWhole
        case failed(ChromiumRuntimeInstallError)
    }

    var finish: (@Sendable (Outcome) -> Void)?
    private let handle: FileHandle
    private let existing: Int64
    private let progress: @Sendable (Int64) -> Void
    private var written: Int64
    private var failure: Outcome?

    init(handle: FileHandle, existing: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.existing = existing
        self.progress = progress
        written = existing
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206 where existing > 0:
                try handle.seekToEnd()
            case 200:
                try handle.truncate(atOffset: 0)
                written = 0
            case 416:
                failure = .alreadyWhole
                return .cancel
            default:
                failure = .failed(.http(status))
                return .cancel
            }
        } catch {
            failure = .failed(.filesystem(error.localizedDescription))
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            progress(written)
        } catch {
            failure = .failed(.filesystem(error.localizedDescription))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let outcome: Outcome
        if let failure {
            outcome = failure
        } else if let error {
            outcome = .failed(.transfer((error as? URLError)?.code == .cancelled ? "cancelled" : error.localizedDescription))
        } else {
            outcome = .complete
        }
        finish?(outcome)
        finish = nil
    }
}
