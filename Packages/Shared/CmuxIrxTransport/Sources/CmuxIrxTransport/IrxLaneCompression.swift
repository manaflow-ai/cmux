public import Foundation
import zlib

/// Byte-stream encodings for server->client event lanes.
///
/// The encoding covers the lane's whole byte stream after its descriptor, not
/// individual frames: one compressor lives for the lane's lifetime, so the
/// repeated frame headers and style tables of consecutive render-grid frames
/// compress against each other. Each write ends with a sync flush, so every
/// frame the writer hands over is decodable as soon as its bytes arrive and a
/// frame is never held back waiting for the next one.
///
/// The writer names the encoding in the lane descriptor, so each lane is
/// self-describing. A host only encodes lanes after the client listed the
/// encoding in `mobile.events.subscribe`; an older client never sees one.
public enum IrxLaneEncoding: String, Codable, CaseIterable, Sendable {
    /// Raw DEFLATE (RFC 1951, no zlib header) with `Z_SYNC_FLUSH` per write.
    case deflate

    /// `mobile.events.subscribe` parameter listing the encodings a client
    /// decodes, comma separated.
    public static let subscribeParameterKey = "event_lane_encodings"

    /// The first encoding in a client's advertised list that this build
    /// supports, or nil for identity lanes.
    public static func negotiated(fromSubscribeParameter value: Any?) -> IrxLaneEncoding? {
        guard let list = value as? String else { return nil }
        return list.split(separator: ",")
            .lazy
            .compactMap { IrxLaneEncoding(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .first
    }

    /// The value a client sends to advertise every encoding it decodes.
    public static var subscribeParameterValue: String {
        allCases.map(\.rawValue).joined(separator: ",")
    }
}

public enum IrxLaneCompressionError: Error, Equatable, Sendable {
    case initializationFailed(Int32)
    case compressionFailed(Int32)
    case decompressionFailed(Int32)
    /// The peer ended the DEFLATE stream; a lane never does that.
    case unexpectedStreamEnd
}

/// Streaming raw-DEFLATE compressor with one sync flush per call.
///
/// Not thread-safe: the owner serializes calls in lane write order.
final class IrxDeflateStream {
    private var stream = z_stream()
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    init() throws {
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw IrxLaneCompressionError.initializationFailed(status) }
    }

    deinit {
        deflateEnd(&stream)
    }

    /// Compresses `data` and flushes, so the returned bytes decode to exactly
    /// the input of this and every earlier call.
    func compress(_ data: Data) throws -> Data {
        var output = Data()
        output.reserveCapacity(data.count / 2 + 16)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            let base = input.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            defer {
                stream.next_in = nil
                stream.avail_in = 0
            }
            try scratch.withUnsafeMutableBufferPointer { buffer in
                // A sync flush is complete once deflate returns with output
                // space left over; a full buffer may still hold pending bits.
                repeat {
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let status = deflate(&stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_BUF_ERROR else {
                        throw IrxLaneCompressionError.compressionFailed(status)
                    }
                    let produced = buffer.count - Int(stream.avail_out)
                    output.append(buffer.baseAddress!, count: produced)
                } while stream.avail_out == 0
            }
        }
        return output
    }
}

/// Streaming raw-DEFLATE decompressor for one lane.
///
/// Not thread-safe: the lane's single reader owns it.
final class IrxInflateStream {
    private var stream = z_stream()
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    init() throws {
        let status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw IrxLaneCompressionError.initializationFailed(status) }
    }

    deinit {
        inflateEnd(&stream)
    }

    /// Decompresses every byte of `data` that is decodable now. Bytes of a
    /// partially received block stay buffered inside zlib until the rest
    /// arrives, so the result may be empty.
    func decompress(_ data: Data) throws -> Data {
        var output = Data()
        output.reserveCapacity(data.count * 4)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            let base = input.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            defer {
                stream.next_in = nil
                stream.avail_in = 0
            }
            try scratch.withUnsafeMutableBufferPointer { buffer in
                while true {
                    let pendingInput = stream.avail_in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let status = inflate(&stream, Z_SYNC_FLUSH)
                    switch status {
                    case Z_OK, Z_BUF_ERROR:
                        break
                    case Z_STREAM_END:
                        throw IrxLaneCompressionError.unexpectedStreamEnd
                    default:
                        throw IrxLaneCompressionError.decompressionFailed(status)
                    }
                    let produced = buffer.count - Int(stream.avail_out)
                    output.append(buffer.baseAddress!, count: produced)
                    // Stop once zlib can make no more progress: all input is
                    // consumed and the output buffer was not the limit.
                    let madeProgress = produced > 0 || stream.avail_in != pendingInput
                    if !madeProgress || (stream.avail_in == 0 && stream.avail_out > 0) { break }
                }
            }
        }
        return output
    }
}

/// Encodes every byte written to a lane with the lane's ``IrxLaneEncoding``.
///
/// Compression order must equal write order, so each write is chained behind
/// the previous one; a failed write fails every later write on this lane,
/// because the peer's decompressor can no longer follow the stream.
public actor IrxEncodingLaneWriter: IrxEventLaneWriting {
    private let inner: any IrxEventLaneWriting
    private let deflater: IrxDeflateStream
    private var tail: Task<Void, any Error>?

    public init(_ inner: any IrxEventLaneWriting, encoding: IrxLaneEncoding) throws {
        switch encoding {
        case .deflate:
            deflater = try IrxDeflateStream()
        }
        self.inner = inner
    }

    public func write(_ data: Data) async throws {
        let encoded = try deflater.compress(data)
        let previous = tail
        let inner = inner
        let write = Task {
            try await previous?.value
            try await inner.write(encoded)
        }
        tail = write
        try await write.value
    }

    public func setPriority(_ priority: Int32) async throws {
        try await inner.setPriority(priority)
    }

    public func finish() async {
        _ = try? await tail?.value
        await inner.finish()
    }

    public func reset(errorCode: UInt64) async {
        await inner.reset(errorCode: errorCode)
    }
}

/// Decodes a lane written by ``IrxEncodingLaneWriter``.
public actor IrxDecodingLaneReader: IrxEventLaneReading {
    private let inner: any IrxEventLaneReading
    private let inflater: IrxInflateStream

    public init(_ inner: any IrxEventLaneReading, encoding: IrxLaneEncoding) throws {
        switch encoding {
        case .deflate:
            inflater = try IrxInflateStream()
        }
        self.inner = inner
    }

    public func readRaw() async throws -> Data? {
        guard let chunk = try await inner.readRaw() else { return nil }
        return try inflater.decompress(chunk)
    }

    public func stop(errorCode: UInt64) async {
        await inner.stop(errorCode: errorCode)
    }
}
