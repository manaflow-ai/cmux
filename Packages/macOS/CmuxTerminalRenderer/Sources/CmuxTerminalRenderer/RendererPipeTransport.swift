public import Foundation
internal import Darwin
internal import IOSurface
internal import os
internal import XPC

/// Length-prefixed binary transport used between cmux and one workspace
/// renderer process. XPC dictionaries remain the in-memory protocol model;
/// this codec carries their primitive fields. IOSurfaces cross separately as
/// Mach rights and are referenced by connection-local tokens in pipe frames.
public final class RendererPipeTransport: @unchecked Sendable {
    public enum Error: Swift.Error {
        case invalidFrame
        case unsupportedValue(String)
        case queueLimitExceeded
    }

    public let messages: AsyncStream<RendererXPCObject>

    private let continuation: AsyncStream<RendererXPCObject>.Continuation
    private let writer: Writer
    private let reader: Reader
    private let surfacePortReceiver: RendererSurfacePortReceiver?

    public init(
        reading input: FileHandle,
        writing output: FileHandle,
        bufferingPolicy: AsyncStream<RendererXPCObject>.Continuation.BufferingPolicy,
        surfacePortReceiver: RendererSurfacePortReceiver? = nil,
        surfacePortSender: RendererSurfacePortSender? = nil
    ) {
        let pair = AsyncStream<RendererXPCObject>.makeStream(bufferingPolicy: bufferingPolicy)
        messages = pair.stream
        continuation = pair.continuation
        self.surfacePortReceiver = surfacePortReceiver
        writer = Writer(
            output: output,
            surfacePortSender: surfacePortSender,
            onFailure: pair.continuation.finish
        )
        reader = Reader(
            input: input,
            surfacePortReceiver: surfacePortReceiver,
            continuation: pair.continuation
        )
        reader.start()
    }

    deinit {
        close()
    }

    @discardableResult
    public func send(_ message: RendererXPCObject) -> Bool {
        writer.send(message)
    }

    public func close() {
        writer.close()
        reader.close()
        surfacePortReceiver?.close()
        continuation.finish()
    }
}

private extension RendererPipeTransport {
    static let frameMagic: UInt32 = 0x3150_5243 // "CRP1" in little endian.
    static let maximumFrameBytes = 64 * 1_024 * 1_024

    enum ValueTag: UInt8 {
        case uint64 = 1
        case int64 = 2
        case double = 3
        case bool = 4
        case data = 5
        case string = 6
        case ioSurfaceToken = 7
    }

    static func framed(
        _ message: RendererXPCObject,
        surfacePortSender: RendererSurfacePortSender?
    ) throws -> Data {
        let payload = try encode(message, surfacePortSender: surfacePortSender)
        guard payload.count <= maximumFrameBytes else { throw Error.invalidFrame }
        var frame = Data(capacity: 8 + payload.count)
        frame.appendInteger(frameMagic)
        frame.appendInteger(UInt32(payload.count))
        frame.append(payload)
        return frame
    }

    static func encode(
        _ message: RendererXPCObject,
        surfacePortSender: RendererSurfacePortSender?
    ) throws -> Data {
        guard xpc_get_type(message.value) == XPC_TYPE_DICTIONARY else {
            throw Error.invalidFrame
        }
        var fields = Data()
        var count: UInt16 = 0
        var encodingError: (any Swift.Error)?
        xpc_dictionary_apply(message.value) { keyPointer, value in
            guard encodingError == nil else { return false }
            let key = String(cString: keyPointer)
            guard let keyData = key.data(using: .utf8), keyData.count <= Int(UInt8.max) else {
                encodingError = Error.invalidFrame
                return false
            }
            do {
                let type = xpc_get_type(value)
                let tag: ValueTag
                var encodedValue = Data()
                if key == RendererIPCKey.ioSurface,
                   let surface = IOSurfaceLookupFromXPCObject(value) {
                    guard let surfacePortSender else {
                        throw Error.unsupportedValue(key)
                    }
                    tag = .ioSurfaceToken
                    encodedValue.appendInteger(try surfacePortSender.token(for: surface))
                } else if type == XPC_TYPE_UINT64 {
                    tag = .uint64
                    encodedValue.appendInteger(xpc_uint64_get_value(value))
                } else if type == XPC_TYPE_INT64 {
                    tag = .int64
                    encodedValue.appendInteger(UInt64(bitPattern: xpc_int64_get_value(value)))
                } else if type == XPC_TYPE_DOUBLE {
                    tag = .double
                    encodedValue.appendInteger(xpc_double_get_value(value).bitPattern)
                } else if type == XPC_TYPE_BOOL {
                    tag = .bool
                    encodedValue.append(xpc_bool_get_value(value) ? 1 : 0)
                } else if type == XPC_TYPE_DATA {
                    tag = .data
                    let length = xpc_data_get_length(value)
                    guard length <= maximumFrameBytes else { throw Error.invalidFrame }
                    encodedValue.appendInteger(UInt32(length))
                    if length > 0, let bytes = xpc_data_get_bytes_ptr(value) {
                        encodedValue.append(bytes.assumingMemoryBound(to: UInt8.self), count: length)
                    }
                } else if type == XPC_TYPE_STRING {
                    tag = .string
                    guard let pointer = xpc_string_get_string_ptr(value) else {
                        throw Error.invalidFrame
                    }
                    let length = strlen(pointer)
                    guard length <= maximumFrameBytes else { throw Error.invalidFrame }
                    encodedValue.appendInteger(UInt32(length))
                    encodedValue.append(
                        UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                        count: length
                    )
                } else {
                    throw Error.unsupportedValue(key)
                }
                fields.append(UInt8(keyData.count))
                fields.append(keyData)
                fields.append(tag.rawValue)
                fields.append(encodedValue)
                count &+= 1
            } catch {
                encodingError = error
            }
            return encodingError == nil
        }
        if let encodingError { throw encodingError }
        var payload = Data(capacity: 2 + fields.count)
        payload.appendInteger(count)
        payload.append(fields)
        return payload
    }

    static func decode(
        _ payload: Data,
        surfacePortReceiver: RendererSurfacePortReceiver?
    ) throws -> RendererXPCObject {
        var cursor = DataCursor(data: payload)
        let count: UInt16 = try cursor.readInteger()
        let message = RendererIPCMessage.make(.failure)
        for _ in 0..<count {
            let keyLength: UInt8 = try cursor.readInteger()
            let keyData = try cursor.read(count: Int(keyLength))
            guard let key = String(data: keyData, encoding: .utf8) else {
                throw Error.invalidFrame
            }
            let rawTag: UInt8 = try cursor.readInteger()
            guard let tag = ValueTag(rawValue: rawTag) else { throw Error.invalidFrame }
            switch tag {
            case .uint64:
                xpc_dictionary_set_uint64(message, key, try cursor.readInteger() as UInt64)
            case .int64:
                let bits: UInt64 = try cursor.readInteger()
                xpc_dictionary_set_int64(message, key, Int64(bitPattern: bits))
            case .double:
                let bits: UInt64 = try cursor.readInteger()
                xpc_dictionary_set_double(message, key, Double(bitPattern: bits))
            case .bool:
                let value: UInt8 = try cursor.readInteger()
                xpc_dictionary_set_bool(message, key, value != 0)
            case .data:
                let length: UInt32 = try cursor.readInteger()
                let data = try cursor.read(count: Int(length))
                data.withUnsafeBytes { bytes in
                    xpc_dictionary_set_data(message, key, bytes.baseAddress, bytes.count)
                }
            case .string:
                let length: UInt32 = try cursor.readInteger()
                let data = try cursor.read(count: Int(length))
                guard let string = String(data: data, encoding: .utf8) else {
                    throw Error.invalidFrame
                }
                xpc_dictionary_set_string(message, key, string)
            case .ioSurfaceToken:
                let token: UInt64 = try cursor.readInteger()
                guard let surfacePortReceiver else { throw Error.invalidFrame }
                let surface = try surfacePortReceiver.surface(for: token)
                xpc_dictionary_set_value(message, key, IOSurfaceCreateXPCObject(surface))
            }
        }
        guard cursor.isAtEnd else { throw Error.invalidFrame }
        return RendererXPCObject(message)
    }

    final class Writer: @unchecked Sendable {
        private struct State {
            var packets: [Data] = []
            var head = 0
            var queuedBytes = 0
            var draining = false
            var closed = false
        }

        private static let maximumQueuedBytes = 32 * 1_024 * 1_024
        private let output: FileHandle
        private let surfacePortSender: RendererSurfacePortSender?
        private let onFailure: @Sendable () -> Void
        private let queue = DispatchQueue(label: "com.cmux.renderer-pipe.writer", qos: .userInteractive)
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(
            output: FileHandle,
            surfacePortSender: RendererSurfacePortSender?,
            onFailure: @escaping @Sendable () -> Void
        ) {
            self.output = output
            self.surfacePortSender = surfacePortSender
            self.onFailure = onFailure
        }

        func send(_ message: RendererXPCObject) -> Bool {
            let packet: Data
            do {
                packet = try RendererPipeTransport.framed(
                    message,
                    surfacePortSender: surfacePortSender
                )
            } catch {
                fail()
                return false
            }
            let enqueueResult = state.withLock { state -> Int in
                guard !state.closed,
                      state.queuedBytes + packet.count <= Self.maximumQueuedBytes else {
                    return -1
                }
                state.packets.append(packet)
                state.queuedBytes += packet.count
                guard !state.draining else { return 0 }
                state.draining = true
                return 1
            }
            if enqueueResult == 1 {
                queue.async { [weak self] in self?.drain() }
            }
            if enqueueResult < 0 { fail() }
            return enqueueResult >= 0
        }

        func close() {
            let shouldClose = state.withLock { state -> Bool in
                guard !state.closed else { return false }
                state.closed = true
                state.packets.removeAll(keepingCapacity: false)
                state.queuedBytes = 0
                return true
            }
            if shouldClose { try? output.close() }
        }

        private func drain() {
            while true {
                let packet: Data? = state.withLock { state in
                    guard !state.closed, state.head < state.packets.count else {
                        state.draining = false
                        if state.head > 0 {
                            state.packets.removeAll(keepingCapacity: true)
                            state.head = 0
                        }
                        return nil
                    }
                    let packet = state.packets[state.head]
                    state.head += 1
                    state.queuedBytes -= packet.count
                    if state.head >= 64, state.head * 2 >= state.packets.count {
                        state.packets.removeFirst(state.head)
                        state.head = 0
                    }
                    return packet
                }
                guard let packet else { return }
                guard writeAll(packet) else {
                    fail()
                    return
                }
            }
        }

        private func writeAll(_ packet: Data) -> Bool {
            packet.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return true }
                var written = 0
                while written < bytes.count {
                    let result = Darwin.write(
                        output.fileDescriptor,
                        base.advanced(by: written),
                        bytes.count - written
                    )
                    if result > 0 {
                        written += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        private func fail() {
            close()
            onFailure()
        }
    }

    final class Reader: @unchecked Sendable {
        private let input: FileHandle
        private let surfacePortReceiver: RendererSurfacePortReceiver?
        private let continuation: AsyncStream<RendererXPCObject>.Continuation
        private let queue = DispatchQueue(label: "com.cmux.renderer-pipe.reader", qos: .userInteractive)
        private let closed = OSAllocatedUnfairLock(initialState: false)

        init(
            input: FileHandle,
            surfacePortReceiver: RendererSurfacePortReceiver?,
            continuation: AsyncStream<RendererXPCObject>.Continuation
        ) {
            self.input = input
            self.surfacePortReceiver = surfacePortReceiver
            self.continuation = continuation
        }

        func start() {
            queue.async { [weak self] in self?.run() }
        }

        func close() {
            let shouldClose = closed.withLock { closed -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            if shouldClose { try? input.close() }
        }

        private func run() {
            var buffer = Data()
            var offset = 0
            var readBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
            do {
                while !closed.withLock({ $0 }) {
                    let count = readBuffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(input.fileDescriptor, bytes.baseAddress, bytes.count)
                    }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    readBuffer.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                            buffer.append(base, count: count)
                        }
                    }
                    while buffer.count - offset >= 8 {
                        let magic: UInt32 = try buffer.readInteger(at: offset)
                        let length: UInt32 = try buffer.readInteger(at: offset + 4)
                        guard magic == RendererPipeTransport.frameMagic,
                              length <= RendererPipeTransport.maximumFrameBytes else {
                            throw Error.invalidFrame
                        }
                        let frameEnd = offset + 8 + Int(length)
                        guard frameEnd <= buffer.count else { break }
                        let payload = buffer.subdata(in: (offset + 8)..<frameEnd)
                        continuation.yield(try RendererPipeTransport.decode(
                            payload,
                            surfacePortReceiver: surfacePortReceiver
                        ))
                        offset = frameEnd
                    }
                    if offset > 0, offset >= 64 * 1_024 || offset * 2 >= buffer.count {
                        buffer.removeSubrange(0..<offset)
                        offset = 0
                    }
                }
            } catch {
                // A malformed or broken stream is equivalent to worker exit.
            }
            continuation.finish()
            close()
        }
    }
}

private struct DataCursor {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let value: T = try data.readInteger(at: offset)
        offset += MemoryLayout<T>.size
        return value
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw RendererPipeTransport.Error.invalidFrame
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readInteger<T: FixedWidthInteger>(at offset: Int) throws -> T {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else {
            throw RendererPipeTransport.Error.invalidFrame
        }
        return withUnsafeBytes { bytes in
            T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}
