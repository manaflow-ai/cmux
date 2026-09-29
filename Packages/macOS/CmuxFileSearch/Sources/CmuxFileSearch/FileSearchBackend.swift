import Foundation

/// How a search ended.
public enum FileSearchCompletion: Hashable, Sendable {
    case completed
    /// More than `limit` matches existed; the first `limit` are shown.
    case limited(Int)
    case failed(FileSearchFailure)
}

public enum FileSearchFailure: Hashable, Sendable {
    /// ripgrep is not installed where the search runs.
    case ripgrepNotFound
    /// ripgrep rejected the regular expression. Carries its diagnostic.
    case invalidRegex(String?)
    /// The scope cannot be searched, with a user-facing reason.
    case unavailable(String)
    /// The command failed. `message` is its trimmed stderr, possibly empty.
    case processFailed(status: Int32, message: String)
}

/// Runs one search somewhere (this Mac, an SSH host, a Cloud VM).
///
/// Implementations stream batches into `sink` as they are found and return
/// how the search ended. They stop promptly when their task is cancelled.
public protocol FileSearchBackend: Sendable {
    func search(
        query: FileSearchQuery,
        rootPath: String,
        matchLimit: Int,
        sink: FileSearchBatchMailbox
    ) async -> FileSearchCompletion
}

/// Coalesces batches produced off the main thread until the UI drains them.
///
/// Producers call ``send(_:)`` per decoded chunk. The consumer waits on
/// ``signals``, which buffers at most one wake-up, then takes everything that
/// arrived since the last drain in one merged batch. However fast ripgrep
/// prints, the UI does one update per drain.
public final class FileSearchBatchMailbox: @unchecked Sendable {
    public struct Drain {
        public let groups: [FileSearchFileMatches]
        /// Set once the producer finished and everything before it drained.
        public let completion: FileSearchCompletion?
    }

    public let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [FileSearchFileMatches] = []
    private var completion: FileSearchCompletion?

    public init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream
        signalContinuation = continuation
    }

    public func send(_ groups: [FileSearchFileMatches]) {
        guard !groups.isEmpty else { return }
        lock.lock()
        let isFinished = completion != nil
        if !isFinished { pending.appendMerging(groups) }
        lock.unlock()
        if !isFinished { signalContinuation.yield() }
    }

    public func finish(_ result: FileSearchCompletion) {
        lock.lock()
        let firstFinish = completion == nil
        if firstFinish { completion = result }
        lock.unlock()
        guard firstFinish else { return }
        signalContinuation.yield()
        signalContinuation.finish()
    }

    public func drain() -> Drain {
        lock.lock()
        defer { lock.unlock() }
        let groups = pending
        pending.removeAll(keepingCapacity: true)
        return Drain(groups: groups, completion: completion)
    }
}

/// Runs a command that prints `rg --json` and decodes it as it streams.
/// Shared by the local and SSH backends.
public enum RipgrepStreamingSearch {
    /// Printed on stderr by remote wrappers when `rg` is not on PATH.
    public static let missingRipgrepMarker = "cmux-file-search: rg not found"

    public static func run(
        command: FileSearchCommand,
        matchLimit: Int,
        sink: FileSearchBatchMailbox
    ) async -> FileSearchCompletion {
        let process: FileSearchProcess
        do {
            process = try FileSearchProcess(command: command)
        } catch FileSearchProcess.SpawnError.launchFailed(let code) where code == ENOENT {
            return .failed(.ripgrepNotFound)
        } catch FileSearchProcess.SpawnError.launchFailed(let code) {
            return .failed(.processFailed(status: -1, message: String(cString: strerror(code))))
        } catch {
            return .failed(.processFailed(status: -1, message: String(describing: error)))
        }

        let decoder = RipgrepStreamDecoder(matchLimit: matchLimit)
        return await withTaskCancellationHandler {
            for await chunk in process.standardOutputChunks() {
                if Task.isCancelled { break }
                sink.send(decoder.consume(chunk))
                if decoder.isLimitReached {
                    process.terminate()
                    break
                }
            }
            sink.send(decoder.finish())
            let exit = await process.waitForExit()
            return classify(
                status: exit.status,
                standardError: exit.standardError,
                matchCount: decoder.matchCount,
                limitReached: decoder.isLimitReached,
                matchLimit: matchLimit
            )
        } onCancel: {
            process.terminate()
        }
    }

    /// Maps ripgrep's exit to a completion. Exit 1 means no match; exit 2
    /// after matches means some files were unreadable, which is not a failure
    /// of the search as a whole.
    public static func classify(
        status: Int32,
        standardError: String,
        matchCount: Int,
        limitReached: Bool,
        matchLimit: Int
    ) -> FileSearchCompletion {
        if limitReached { return .limited(matchLimit) }
        if status == 0 || status == 1 { return .completed }
        let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains(missingRipgrepMarker) || (status == 127 && message.isEmpty) {
            return .failed(.ripgrepNotFound)
        }
        if message.contains("regex parse error") || message.contains("error parsing regex") ||
            message.contains("PCRE2") && message.contains("error") {
            return .failed(.invalidRegex(message))
        }
        if status == 2, matchCount > 0 { return .completed }
        return .failed(.processFailed(status: status, message: message))
    }
}
