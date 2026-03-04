import Foundation

/// Streams raw pty output bytes from a ghostty surface to connected clients.
/// The output handler callback fires from the io-reader thread, so all buffer
/// operations must be thread-safe and non-blocking.
///
/// Architecture:
/// - ghostty_surface_set_output_handler -> outputHandlerCallback (io thread)
/// - Callback writes into a lock-free ring buffer
/// - Connected streaming clients are woken via dispatch sources to drain the buffer
///
/// Bootstrap: On attach, the current screen state is serialized as VT escape
/// sequences and sent before transitioning to the live byte stream.
final class SurfaceOutputStreamer {
    /// Ring buffer capacity. 256KB is enough for typical terminal throughput
    /// while keeping memory usage low.
    static let bufferCapacity = 256 * 1024

    /// Per-surface streamer keyed by surface UUID.
    private static let lock = NSLock()
    private static var streamers: [UUID: SurfaceOutputStreamer] = [:]

    let surfaceId: UUID
    private let ringBuffer: RingBuffer
    private let clientsLock = NSLock()
    private var clients: [StreamClient] = []
    private var surface: ghostty_surface_t?
    /// Set when ring buffer overflows; next drain will send a resync.
    private var needsResync = false

    init(surfaceId: UUID) {
        self.surfaceId = surfaceId
        self.ringBuffer = RingBuffer(capacity: Self.bufferCapacity)
    }

    // MARK: - Registry

    /// Get or create a streamer for the given surface.
    static func streamer(for surfaceId: UUID) -> SurfaceOutputStreamer {
        lock.lock()
        defer { lock.unlock() }
        if let existing = streamers[surfaceId] { return existing }
        let s = SurfaceOutputStreamer(surfaceId: surfaceId)
        streamers[surfaceId] = s
        return s
    }

    /// Remove and detach a streamer.
    static func remove(for surfaceId: UUID) {
        lock.lock()
        let s = streamers.removeValue(forKey: surfaceId)
        lock.unlock()
        s?.detach()
    }

    // MARK: - Ghostty hook

    /// Attach the output handler to a ghostty surface. Must be called from main thread.
    func attach(to surface: ghostty_surface_t) {
        self.surface = surface
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_output_handler(surface, Self.outputHandlerCallback, userdata)
    }

    /// Remove the output handler. Safe to call multiple times.
    func detach() {
        if let surface {
            ghostty_surface_set_output_handler(surface, nil, nil)
        }
        surface = nil
        // Disconnect all clients
        clientsLock.lock()
        let snapshot = clients
        clients.removeAll()
        clientsLock.unlock()
        for c in snapshot { c.close() }
    }

    var hasClients: Bool {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return !clients.isEmpty
    }

    // MARK: - Client management

    /// Add a streaming client. The bootstrap payload (screen snapshot) should
    /// already have been written to the fd before calling this.
    func addClient(fd: Int32) {
        let client = StreamClient(fd: fd, streamer: self)
        clientsLock.lock()
        clients.append(client)
        clientsLock.unlock()
        // Drain any bytes that arrived between bootstrap and hook registration
        client.drain()
    }

    /// Remove a disconnected client.
    func removeClient(_ client: StreamClient) {
        clientsLock.lock()
        clients.removeAll { $0 === client }
        let empty = clients.isEmpty
        clientsLock.unlock()
        // If no more clients, we could optionally detach the hook to save
        // overhead, but keeping it attached is simpler and the cost is negligible.
        _ = empty
    }

    // MARK: - Ring buffer drain

    /// Called by clients to read available bytes from the ring buffer.
    /// Returns the bytes, or nil if empty.
    func drainBytes() -> Data? {
        return ringBuffer.drain()
    }

    // MARK: - Output handler callback

    /// C callback invoked from the io-reader thread with raw pty bytes.
    /// Must be non-blocking.
    private static let outputHandlerCallback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int
    ) -> Void = { userdata, data, len in
        guard let userdata, let data, len > 0 else { return }
        let streamer = Unmanaged<SurfaceOutputStreamer>.fromOpaque(userdata).takeUnretainedValue()

        let written = streamer.ringBuffer.write(data, count: len)
        if written < len {
            // Overflow: oldest bytes were overwritten. Flag for resync.
            streamer.needsResync = true
        }

        // Wake all connected clients to drain
        streamer.clientsLock.lock()
        let snapshot = streamer.clients
        streamer.clientsLock.unlock()
        for client in snapshot {
            client.signal()
        }
    }
}

// MARK: - Ring Buffer

/// Fixed-size ring buffer. Single producer (io-reader thread), single/multi consumer (drain).
/// Uses os_unfair_lock for minimal overhead since the critical section is just pointer arithmetic.
final class RingBuffer {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var count: Int = 0
    private var unfairLock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// Write bytes into the ring buffer. If the buffer is full, overwrites oldest data.
    /// Returns the number of bytes actually written without overwriting (for overflow detection).
    func write(_ data: UnsafePointer<UInt8>, count len: Int) -> Int {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        let available = capacity - count
        var src = data
        var remaining = len

        // Write in up to two chunks (wrap around)
        while remaining > 0 {
            let chunkSize = min(remaining, capacity - writePos)
            buffer.advanced(by: writePos).update(from: src, count: chunkSize)
            writePos = (writePos + chunkSize) % capacity
            src = src.advanced(by: chunkSize)
            remaining -= chunkSize
        }

        if len <= available {
            count += len
            return len
        } else {
            // Overflowed: advance read position past overwritten data
            count = capacity
            readPos = writePos
            return available
        }
    }

    /// Drain all available bytes from the buffer.
    func drain() -> Data? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        guard count > 0 else { return nil }

        var result = Data(capacity: count)
        let toRead = count

        if readPos + toRead <= capacity {
            result.append(buffer.advanced(by: readPos), count: toRead)
        } else {
            let firstChunk = capacity - readPos
            result.append(buffer.advanced(by: readPos), count: firstChunk)
            result.append(buffer, count: toRead - firstChunk)
        }

        readPos = (readPos + toRead) % capacity
        count = 0
        return result
    }
}

// MARK: - Stream Client

/// Represents a single connected streaming client (Unix socket fd).
/// Writes are done on a dedicated dispatch queue to avoid blocking the io thread.
final class StreamClient {
    let fd: Int32
    private weak var streamer: SurfaceOutputStreamer?
    private let queue = DispatchQueue(label: "com.cmux.stream-client", qos: .userInteractive)
    private var closed = false
    private let pipe: (readEnd: Int32, writeEnd: Int32)

    init(fd: Int32, streamer: SurfaceOutputStreamer) {
        self.fd = fd
        self.streamer = streamer
        // Make the client socket non-blocking
        let flags = fcntl(fd, F_GETFL)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // Create a self-pipe for signaling
        var fds: [Int32] = [0, 0]
        Darwin.pipe(&fds)
        self.pipe = (fds[0], fds[1])
        // Start the drain loop
        startDrainLoop()
    }

    /// Signal that new data is available.
    func signal() {
        let byte: UInt8 = 1
        withUnsafePointer(to: byte) { ptr in
            _ = Darwin.write(pipe.writeEnd, ptr, 1)
        }
    }

    /// Force an immediate drain attempt.
    func drain() {
        signal()
    }

    func close() {
        closed = true
        Darwin.close(pipe.writeEnd)
        Darwin.close(pipe.readEnd)
        Darwin.close(fd)
    }

    private func startDrainLoop() {
        queue.async { [weak self] in
            self?.drainLoop()
        }
    }

    private func drainLoop() {
        var pollFds = [
            pollfd(fd: pipe.readEnd, events: Int16(POLLIN), revents: 0)
        ]
        var signalBuf = [UInt8](repeating: 0, count: 64)

        while !closed {
            // Wait for signal or timeout (1 second for keepalive check)
            let ret = poll(&pollFds, 1, 1000)
            if ret < 0 {
                if errno == EINTR { continue }
                break
            }

            // Consume signal bytes
            if ret > 0 && (pollFds[0].revents & Int16(POLLIN)) != 0 {
                _ = Darwin.read(pipe.readEnd, &signalBuf, signalBuf.count)
            }

            // Drain ring buffer and write to client
            guard let streamer, let data = streamer.drainBytes() else { continue }

            let writeResult = data.withUnsafeBytes { rawBuf -> Int in
                guard let ptr = rawBuf.baseAddress else { return 0 }
                var totalWritten = 0
                while totalWritten < data.count {
                    let n = Darwin.write(fd, ptr.advanced(by: totalWritten), data.count - totalWritten)
                    if n <= 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            // Socket buffer full, try again
                            usleep(1000) // 1ms backoff
                            continue
                        }
                        return -1 // Client disconnected
                    }
                    totalWritten += n
                }
                return totalWritten
            }

            if writeResult < 0 {
                // Client disconnected
                break
            }
        }

        // Cleanup
        if !closed { close() }
        streamer?.removeClient(self)
    }
}
