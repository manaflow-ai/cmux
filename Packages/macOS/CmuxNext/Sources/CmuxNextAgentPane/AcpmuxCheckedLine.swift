import Darwin
public import Foundation

/// A line-delimited JSON connection to this app's acpmux whose server peer is checked on its
/// own descriptor before the first byte is written (cx-fcaq, cx-aocz review P1): the app's
/// person proof goes only to the acpmux this app runs, never to a listener that took the socket
/// path after an earlier probe. All state lives on one serial queue; callbacks run there and
/// callers hop to their own actor.
public nonisolated final class AcpmuxCheckedLine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.acpmux.checked-line")
    private let environment: AcpmuxEnvironment
    private var descriptor: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false
    /// Largest line accepted.
    static let maxLine = 16 * 1024 * 1024

    public init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    /// Connects, checks the server peer on this connection (own path only), then sends `send`.
    /// A refused or failed connect closes at once (`onClose`).
    public func start(send: Data, onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onLine = onLine
            self.onClose = onClose
            do {
                descriptor = try AcpmuxServerPeer.connectChecked(socketPath: environment.socketPath,
                                                                 executable: environment.executable)
            } catch {
                return finish()
            }
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            reader.setEventHandler { [weak self] in self?.readable() }
            source = reader
            reader.resume()
            write(send)
        }
    }

    /// Sends another request on the live connection.
    public func send(_ data: Data) {
        queue.async { [self] in write(data) }
    }

    public func cancel() {
        queue.async { [self] in
            onClose = nil
            onLine = nil
            finish()
        }
    }

    private func write(_ data: Data) {
        guard !closed, descriptor >= 0 else { return }
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return finish() }
            offset += sent
        }
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else { return finish() }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(line) }
        }
        if buffer.count > Self.maxLine { finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        let callback = onClose
        onClose = nil
        onLine = nil
        callback?()
    }
}
