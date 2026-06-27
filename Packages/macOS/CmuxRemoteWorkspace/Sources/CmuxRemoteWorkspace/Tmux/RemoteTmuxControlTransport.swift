import Foundation

/// Subprocess + pipe-plumbing sub-model for one `tmux -CC` control connection.
///
/// Owns the `ssh tmux -CC` `Process`, its three pipes, the bounded off-main stdin
/// writer, and the two `AsyncStream` consumer tasks that pump stdout into the
/// app-side parser and stderr into the app-side captured buffer. Drives its owning
/// connection through ``RemoteTmuxControlTransportHost`` (stdout chunk, stream-end,
/// stderr text, stdin-write failure, stdout backpressure), so the message parsing,
/// session-gone classification, and connection-state machine stay app-side while only
/// the raw subprocess and pipe bytes live here. The connection computes the ssh
/// argument vector (`RemoteTmuxHost.controlModeArguments`) app-side and passes it to
/// ``spawn(arguments:)``; this transport never references the host descriptor.
@MainActor
public final class RemoteTmuxControlTransport {
    private weak var host: (any RemoteTmuxControlTransportHost)?

    private var process: Process?
    private var stdinWriter: RemoteTmuxControlPipeWriter?
    private var stdoutReader: FileHandle?
    private var stderrReader: FileHandle?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    /// Consumes the current spawn's stderr into the host's captured buffer. Awaited
    /// (via ``awaitStderrDrained()``) before a failed reconnect attempt is classified,
    /// so the decision sees the complete error rather than racing the async stderr
    /// delivery.
    private var stderrTask: Task<Void, Never>?
    /// Consumes the current spawn's stdout, forwarding each chunk to the host parser
    /// in order and signalling stream-end when it finishes.
    private var ingestTask: Task<Void, Never>?

    /// Cap queued stdin bytes while the dedicated writer is backpressured. Above
    /// this, writes are rejected and the connection reconnects instead of accepting
    /// unbounded user input that may never reach tmux.
    private static let maxPendingStdinBytes = 256 * 1024
    /// Cap pending stdout chunks between SSH's pipe callback and the main-actor
    /// parser. A full buffer means parsing/rendering has fallen behind remote
    /// output; reconnecting and re-seeding is safer than corrupting the stream by
    /// dropping arbitrary control-mode bytes or growing memory without bound.
    private static let maxPendingStdoutChunks = 16

    public init() {}

    /// Injects the owning connection as the byte/lifecycle seam. Call once right after
    /// the connection constructs the transport.
    public func attach(host: any RemoteTmuxControlTransportHost) {
        self.host = host
    }

    /// `true` while a live stdin writer exists for the current spawn.
    public var hasStdinWriter: Bool { stdinWriter != nil }

    /// Queues `data` on the current spawn's stdin writer. Returns `false` when there is
    /// no live writer or the writer's bounded budget rejects the write.
    public func enqueueStdin(_ data: Data) -> Bool {
        guard let stdinWriter else { return false }
        return stdinWriter.enqueue(data)
    }

    /// Awaits the current spawn's stderr consumer finishing (stderr EOF / process
    /// exit), so the connection can read the complete captured stderr before
    /// classifying a failed reconnect.
    public func awaitStderrDrained() async {
        await stderrTask?.value
    }

    /// Spawns the `ssh tmux -CC` process for `arguments` and wires its stdout into the
    /// host parser, consuming stderr for session-gone classification. The connection
    /// resets its own per-spawn state (parser, pending-command FIFO, captured stderr,
    /// `enterReceived`) before calling this; this transport only owns the subprocess
    /// and pipe handles.
    public func spawn(arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let stdinWriter = RemoteTmuxControlPipeWriter(
            handle: inPipe.fileHandleForWriting,
            label: "com.cmux.remote-tmux.stdin.\(UUID().uuidString)",
            maxPendingBytes: Self.maxPendingStdinBytes,
            onFailure: { [weak self] in
                self?.host?.transportStdinWriteDidFail()
            }
        )

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maxPendingStdoutChunks)
        )
        let reader = outPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }

            switch continuation.yield(chunk) {
            case .enqueued:
                break
            case .dropped, .terminated:
                handle.readabilityHandler = nil
                continuation.finish()
                Task { @MainActor [weak self] in
                    self?.host?.transportStdoutBackpressureDidOverflow()
                }
            @unknown default:
                handle.readabilityHandler = nil
                continuation.finish()
                Task { @MainActor [weak self] in
                    self?.host?.transportStdoutBackpressureDidOverflow()
                }
            }
        }
        // Capture stderr via its own AsyncStream so a failed reconnect attempt can be
        // classified deterministically: the connection awaits `awaitStderrDrained()`
        // (which finishes on stderr EOF) before reading its captured buffer, so the
        // decision can't race a not-yet-delivered chunk.
        let (errStream, errContinuation) = AsyncStream<Data>.makeStream()
        let errReader = errPipe.fileHandleForReading
        errReader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errContinuation.finish()
            } else {
                errContinuation.yield(chunk)
            }
        }
        // Finish BOTH streams on process exit so the consumers (and any awaiter)
        // always complete even if a reader's EOF callback is delayed.
        proc.terminationHandler = { _ in
            continuation.finish()
            errContinuation.finish()
        }

        do {
            try proc.run()
        } catch {
            // Don't latch the connection started on a failed launch, so a later attach
            // can replace this connection instead of reusing a dead one. Close the
            // stdin writer too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            reader.readabilityHandler = nil
            errReader.readabilityHandler = nil
            continuation.finish()
            errContinuation.finish()
            stdinWriter.close()
            throw error
        }
        process = proc
        self.stdinWriter = stdinWriter
        stdoutReader = reader
        stderrReader = errReader
        streamContinuation = continuation
        stderrContinuation = errContinuation
        stderrTask = Task { [weak self] in
            for await chunk in errStream {
                guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { continue }
                self?.host?.transportDidReceiveStderrText(text)
            }
        }
        ingestTask = Task { [weak self] in
            for await chunk in stream {
                self?.host?.transportDidReceiveStdoutChunk(chunk)
            }
            await self?.host?.transportStreamDidEnd()
        }
    }

    /// Tears down the current spawn's process and I/O handles WITHOUT signalling the
    /// connection, so the connection can either end (``RemoteTmuxControlConnection/stop()``)
    /// or re-spawn (reconnect) from a clean slate.
    public func teardown() {
        ingestTask?.cancel()
        ingestTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminationHandler = nil
        // Tear down the readers deterministically rather than waiting for EOF (the
        // consumers are already cancelled).
        stdoutReader?.readabilityHandler = nil
        stdoutReader = nil
        stderrReader?.readabilityHandler = nil
        stderrReader = nil
        streamContinuation?.finish()
        streamContinuation = nil
        stderrContinuation?.finish()
        stderrContinuation = nil
        stdinWriter?.close()
        stdinWriter = nil
        process?.terminate()
        process = nil
    }

    #if DEBUG
    public func installStdinWriterForTesting(_ writer: RemoteTmuxControlPipeWriter) { stdinWriter = writer }
    #endif
}
