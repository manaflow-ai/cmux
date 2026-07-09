public import Foundation

/// Accumulates the stdout/stderr of a VS Code `serve-web` process line by line,
/// resolving the advertised Web UI URL as soon as a `Web UI available at <url>`
/// line is seen, and signals waiters through a semaphore.
///
/// Isolation: a byte-faithful lift of the former app-target collector. State is
/// guarded by an `NSLock` (not an actor) because ``waitForURL(timeoutSeconds:)``
/// blocks the launch thread on a `DispatchSemaphore`, a synchronous contract the
/// launch path depends on; the lock makes the buffer safe to touch from the
/// pipe readability/termination handlers and the waiting launch thread, which is
/// why the type is `@unchecked Sendable`.
public final class ServeWebOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didSignal = false

    /// Creates an empty collector.
    public init() {}

    /// The resolved Web UI URL, or `nil` until one is parsed.
    public var webUIURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedURL
    }

    /// Appends a chunk of process output, resolving (and signalling) the Web UI
    /// URL as soon as a complete matching line is buffered.
    public func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard resolvedURL == nil else { return }
        outputBuffer.append(text)
        while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            guard let parsedURL = URL.vscodeServeWebUIURL(parsedFrom: line) else {
                continue
            }
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                didSignal = true
                semaphore.signal()
            }
            return
        }
    }

    /// Flushes any buffered final line (which may lack a trailing newline) and
    /// signals waiters that the process has exited.
    public func markProcessExited() {
        lock.lock()
        defer { lock.unlock() }
        if resolvedURL == nil, !outputBuffer.isEmpty,
           let parsedURL = URL.vscodeServeWebUIURL(parsedFrom: outputBuffer) {
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    /// Blocks until a URL is resolved or `timeoutSeconds` elapses, returning
    /// whether a URL is available.
    public func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }
}
