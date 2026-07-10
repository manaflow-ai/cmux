import Dispatch
import Foundation

// FileHandle delivers readiness callbacks off the cooperative executor; parsing stays serialized on `queue`.
final class CuaDriverFileReader: @unchecked Sendable {
    typealias LineContinuation = AsyncThrowingStream<String, Error>.Continuation
    typealias DrainContinuation = AsyncStream<Void>.Continuation

    private let queue = DispatchQueue(label: "com.cmux.cua-driver.pipe-reader", qos: .utility)
    private let handle: FileHandle
    private var lineContinuation: LineContinuation?
    private var drainContinuation: DrainContinuation?
    private var buffer = Data()
    private var isFinished = false

    init(fileDescriptor: Int32, continuation: LineContinuation) {
        self.lineContinuation = continuation
        self.handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }

    init(fileDescriptor: Int32, continuation: DrainContinuation) {
        self.drainContinuation = continuation
        self.handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                self?.consumeRead(data)
            }
        }
    }

    func cancel() {
        handle.readabilityHandler = nil
        queue.async { [self] in
            finish()
        }
    }

    private func consumeRead(_ data: Data) {
        guard !isFinished else { return }
        if data.isEmpty {
            finishAtEOF()
        } else {
            consume(data)
        }
    }

    private func consume(_ data: Data) {
        guard lineContinuation != nil else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            let next = buffer.index(after: newline)
            buffer.removeSubrange(..<next)
            guard let line = String(data: lineData, encoding: .utf8) else {
                finish(throwing: CuaDriverManagerError.invalidUTF8)
                return
            }
            lineContinuation?.yield(
                line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            )
        }
    }

    private func finishAtEOF() {
        if lineContinuation != nil, !buffer.isEmpty {
            guard let line = String(data: buffer, encoding: .utf8) else {
                finish(throwing: CuaDriverManagerError.invalidUTF8)
                return
            }
            lineContinuation?.yield(line)
        }
        finish()
    }

    private func finish(throwing error: Error? = nil) {
        guard !isFinished else { return }
        isFinished = true
        handle.readabilityHandler = nil

        let lines = lineContinuation
        let drain = drainContinuation
        lineContinuation = nil
        drainContinuation = nil
        buffer.removeAll(keepingCapacity: false)

        if let error {
            lines?.finish(throwing: error)
        } else {
            lines?.finish()
        }
        drain?.finish()
        try? handle.close()
    }
}
