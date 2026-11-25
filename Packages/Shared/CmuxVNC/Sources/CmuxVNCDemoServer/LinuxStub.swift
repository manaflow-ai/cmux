#if !canImport(CoreGraphics) || !canImport(CoreText) || !canImport(Network)
import Foundation

/// The demo server is unavailable when the platform has no graphics or Network framework.
public final class VNCDemoServer: Sendable {
    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var name: String
        public var password: String?
        public var framesPerSecond: Int
        public init(width: Int = 1280, height: Int = 800, name: String = "cmux VNC demo", password: String? = nil, framesPerSecond: Int = 30) {
            self.width = width; self.height = height; self.name = name; self.password = password; self.framesPerSecond = framesPerSecond
        }
    }
    public let configuration: Configuration
    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }
    public func start(port: UInt16 = 0) async throws -> UInt16 { throw NSError(domain: "CmuxVNCDemoServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Demo server requires Apple graphics and Network frameworks"]) }
    public func stop() {}
    public func typedText() async -> String { "" }
}
#endif
#if !canImport(CoreGraphics) || !canImport(CoreText) || !canImport(Network)
import zlib

final class Deflater {
    private let stream: UnsafeMutablePointer<z_stream>
    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        _ = deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }
    deinit { _ = deflateEnd(stream); stream.deinitialize(count: 1); stream.deallocate() }
    func deflate(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        input.withUnsafeMutableBufferPointer { source in
            stream.pointee.next_in = source.baseAddress
            stream.pointee.avail_in = uInt(source.count)
            repeat {
                let produced = chunk.withUnsafeMutableBufferPointer { out -> Int in
                    stream.pointee.next_out = out.baseAddress
                    stream.pointee.avail_out = uInt(out.count)
                    _ = zlib.deflate(stream, Z_SYNC_FLUSH)
                    return out.count - Int(stream.pointee.avail_out)
                }
                result.append(contentsOf: chunk[0 ..< produced])
            } while stream.pointee.avail_out == 0
        }
        return result
    }
}
#endif
