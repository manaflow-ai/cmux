public import Foundation

/// Optional zlib compression for mobile sync EVENT frames.
///
/// A compressed frame is `[0x01][zlib-compressed JSON envelope]`. The magic
/// byte can never begin a JSON envelope (those start with `{`, 0x7B), so a
/// decoder that checks the first byte handles old and new senders alike. The
/// capability is negotiated at `mobile.events.subscribe` time with
/// `event_compression: "deflate"`; a sender must never emit a compressed
/// frame to a connection that did not ask for one. Only event frames are
/// compressed (that is where the bytes are: render-grid deltas and full
/// frames); requests and responses stay plain.
public enum MobileEventFrameCompression {
    /// First byte of a compressed frame payload.
    public static let compressedFrameMagic: UInt8 = 0x01
    /// The subscribe-parameter value that opts a connection in.
    public static let deflateParameterValue = "deflate"
    /// Frames smaller than this are sent plain: zlib overhead and the extra
    /// copy are not worth it below roughly one MTU of JSON.
    public static let minimumCompressibleByteCount = 256

    /// `[magic][zlib(envelope)]`, or nil when compression fails or does not
    /// shrink the payload (the caller then sends the plain frame).
    public static func compressedPayload(for envelope: Data) -> Data? {
        guard envelope.count >= minimumCompressibleByteCount else { return nil }
        guard let compressed = try? (envelope as NSData).compressed(using: .zlib) as Data,
              compressed.count + 1 < envelope.count else {
            return nil
        }
        var out = Data(capacity: compressed.count + 1)
        out.append(compressedFrameMagic)
        out.append(compressed)
        return out
    }

    /// The plain envelope for `frame`. A frame without the magic byte is
    /// returned unchanged. A magic-prefixed frame is inflated with
    /// `maximumInflatedByteCount` as the hard output cap (a frame claiming to
    /// inflate past the codec's frame limit is hostile or corrupt); nil means
    /// the frame was compressed but could not be inflated, and the caller
    /// should drop it exactly like an unparseable envelope.
    public static func inflatedFrame(
        _ frame: Data,
        maximumInflatedByteCount: Int
    ) -> Data? {
        guard frame.first == compressedFrameMagic else { return frame }
        guard frame.count > 1,
              let inflated = try? (frame.dropFirst() as NSData).decompressed(using: .zlib) as Data,
              inflated.count <= maximumInflatedByteCount else {
            return nil
        }
        return inflated
    }
}
