import Foundation

/// Picks the largest pasted-image encoding that still fits the mobile sync
/// wire protocol's frame budget.
///
/// An image pasted on the phone is base64-encoded into the `terminal.paste_image`
/// request's JSON body before it is framed and sent to the Mac. The frame codec
/// (``MobileSyncFrameCodec``) rejects any payload larger than
/// ``MobileSyncFrameCodec/defaultMaximumFrameByteCount``, and that base64 JSON is
/// the *first* (and tightest) limit the image hits — base64 inflates raw bytes by
/// ~4/3, so a raw image near the Mac's own 10 MB clipboard cap (~13.3 MB base64)
/// would blow the 8 MB frame cap before it ever left the device. This type derives
/// the real raw-byte ceiling from the frame cap so callers cap *before* sending and
/// never hand the transport a frame that is doomed to throw `frameTooLarge`.
///
/// ```swift
/// let sizing = MobilePasteImageSizing()
/// if let candidate = sizing.firstCandidateThatFits([
///     (png, "png"),
///     (jpeg, "jpg"),
/// ]) {
///     onPasteImage(candidate.data, candidate.format)
/// } else {
///     onPasteImageTooLarge() // every encoding is too big to send
/// }
/// ```
public struct MobilePasteImageSizing: Sendable {
    /// The frame payload budget the encoded request must fit within.
    public let frameByteCapacity: Int

    /// Bytes reserved for the JSON request envelope around `image_base64`
    /// (the two UUID ids, `client_id`, `image_format`, key names, and JSON
    /// punctuation) **plus the `auth` object the RPC client injects after this
    /// helper sizes the image** (a Stack access token, and sometimes an attach
    /// token, each a multi-KB JWT). Those tokens are added by
    /// `requestDataWithAuth` once the request is already approved, so the reserve
    /// must cover them or an image accepted at the cap can still overflow the
    /// frame once auth is attached. Generous on purpose: 16 KiB comfortably holds
    /// two several-KB JWTs and only trims the raw cap by a few KB.
    public let envelopeReserveBytes: Int

    /// Worst-case multiplier applied to the base64 length to bound JSON
    /// serialization growth.
    ///
    /// Apple's `JSONSerialization` escapes `/` as `\/`, and `/` is one of the 64
    /// base64 symbols. The maximal-slash case (raw `0xFF` bytes encode to `////`)
    /// doubles the base64 portion of the serialized request, so the encoded image
    /// can be up to `2 ×` its base64 length once framed. Budgeting for that worst
    /// case here keeps `firstCandidateThatFits` from approving an image that would
    /// still throw `frameTooLarge` at the transport.
    public let jsonEscapeWorstCaseFactor: Int

    /// Creates a sizing helper bound to a frame budget.
    ///
    /// - Parameters:
    ///   - frameByteCapacity: The maximum frame payload size, defaulting to the
    ///     protocol's ``MobileSyncFrameCodec/defaultMaximumFrameByteCount``.
    ///   - envelopeReserveBytes: Bytes reserved for the JSON envelope around the
    ///     base64 image **and the post-sizing `auth` object** (Stack + attach
    ///     JWTs). Defaults to 16 KiB so two several-KB tokens cannot push an
    ///     at-the-cap image past the frame budget. The reserve is face-value (it
    ///     is subtracted before the slash-escape factor) because JWTs are
    ///     base64url, which `JSONSerialization` does not slash-escape.
    ///   - jsonEscapeWorstCaseFactor: Worst-case multiplier on the base64 length
    ///     to cover JSON slash-escaping. Defaults to 2 (the all-slash base64 case).
    public init(
        frameByteCapacity: Int = MobileSyncFrameCodec.defaultMaximumFrameByteCount,
        envelopeReserveBytes: Int = 16 * 1024,
        jsonEscapeWorstCaseFactor: Int = 2
    ) {
        self.frameByteCapacity = frameByteCapacity
        self.envelopeReserveBytes = envelopeReserveBytes
        self.jsonEscapeWorstCaseFactor = max(1, jsonEscapeWorstCaseFactor)
    }

    /// The base64 length, in bytes, that `rawByteCount` raw bytes encode to.
    ///
    /// Standard base64 emits 4 characters per 3 input bytes, padded up to the
    /// next multiple of 4, so the encoded length is `4 * ceil(n / 3)`.
    ///
    /// - Parameter rawByteCount: The number of raw bytes to be encoded.
    /// - Returns: The exact base64 character/byte count.
    public func base64ByteCount(forRawByteCount rawByteCount: Int) -> Int {
        guard rawByteCount > 0 else { return 0 }
        return ((rawByteCount + 2) / 3) * 4
    }

    /// The largest raw image size that fits the frame budget under the *worst
    /// case* (every base64 character slash-escaped).
    ///
    /// This is the conservative bound: an image at or under this size is
    /// guaranteed to fit no matter how dense its slashes are. It is *not* used to
    /// reject images on its own, because real PNG/JPEG data is nowhere near
    /// all-slash, so rejecting a 4 MB photo on this worst-case cap would drop
    /// images that actually fit. ``fits(imageData:)`` measures the real escaped
    /// size instead; this value remains useful as a quick lower bound and as a
    /// documented worst-case guarantee.
    ///
    /// The serialized base64 can grow to `jsonEscapeWorstCaseFactor × base64Len`,
    /// so the base64 itself must satisfy
    /// `factor * base64Len <= frameCap - envelope`. Inverting
    /// `base64Len = 4 * ceil(raw / 3)` then gives
    /// `raw <= floor((frameCap - envelope) / factor / 4) * 3`, the value returned
    /// here.
    ///
    /// - Returns: The maximum raw byte count that is guaranteed to encode and
    ///   frame successfully even under maximal slash escaping, never negative.
    public var maximumRawImageByteCount: Int {
        let base64Budget = (frameByteCapacity - envelopeReserveBytes) / jsonEscapeWorstCaseFactor
        guard base64Budget > 0 else { return 0 }
        return (base64Budget / 4) * 3
    }

    /// Whether an image of `rawByteCount` raw bytes is guaranteed to fit the frame
    /// budget under the worst-case slash density.
    ///
    /// Prefer ``fits(imageData:)`` when the encoded bytes are in hand: this
    /// worst-case check is conservative and rejects typical large images that
    /// actually fit. It exists for callers that only know a raw byte count.
    ///
    /// - Parameter rawByteCount: The raw byte count of an encoded image candidate.
    /// - Returns: `true` when the candidate is safe to send in the worst case.
    public func fits(rawByteCount: Int) -> Bool {
        rawByteCount > 0 && rawByteCount <= maximumRawImageByteCount
    }

    /// The exact serialized size, in bytes, of `imageData`'s base64 once placed in
    /// the request's `image_base64` JSON string.
    ///
    /// `JSONSerialization` escapes each `/` as `\/` (a one-byte growth) and leaves
    /// every other base64 character (`A–Z a–z 0–9 +`) and `=` padding untouched,
    /// so the field's serialized length is `base64Length + (count of '/')`.
    /// Measuring the actual slash count (instead of assuming every character is a
    /// slash) is what lets a typical multi-MB photo through while still catching a
    /// genuinely overflowing payload, since all-`/` data measures up to exactly the
    /// `2×` worst case and hits the same boundary.
    ///
    /// - Parameter imageData: The raw encoded image bytes (e.g. PNG or JPEG).
    /// - Returns: The serialized byte count the base64 string contributes.
    public func escapedImageFieldByteCount(forImageData imageData: Data) -> Int {
        let base64 = imageData.base64EncodedData()
        let slashByte = UInt8(ascii: "/")
        var slashCount = 0
        for byte in base64 where byte == slashByte {
            slashCount += 1
        }
        return base64.count + slashCount
    }

    /// Whether `imageData` actually fits the frame budget once base64-encoded into
    /// the request, measured against its real (not worst-case) slash escaping.
    ///
    /// Uses ``escapedImageFieldByteCount(forImageData:)`` plus the envelope/auth
    /// reserve, so a typical large photo that genuinely fits is accepted while a
    /// payload that would overflow the frame (including the adversarial all-slash
    /// case) is rejected.
    ///
    /// - Parameter imageData: The raw encoded image bytes of a candidate.
    /// - Returns: `true` when the candidate is safe to send.
    public func fits(imageData: Data) -> Bool {
        guard !imageData.isEmpty else { return false }
        return escapedImageFieldByteCount(forImageData: imageData) + envelopeReserveBytes <= frameByteCapacity
    }

    /// The first lazily-encoded candidate, in priority order, that actually fits
    /// the frame budget, paired with its label.
    ///
    /// Callers pass labeled encoders in preference order (e.g. `("png", …)` first,
    /// then a lower-quality `("jpg", …)`). Each encoder is invoked only when
    /// reached, and a non-fitting candidate's `Data` is dropped before the next
    /// encoder runs, so two full encodings are never retained at once (a large
    /// pasteboard image would otherwise keep both the failed PNG and the JPEG
    /// fallback alive and risk memory pressure). Returning `nil` means every
    /// candidate is too large to transmit and the caller should surface a "too
    /// large" notice instead of sending an oversized frame the transport would
    /// reject.
    ///
    /// ```swift
    /// let sizing = MobilePasteImageSizing()
    /// if let (format, data) = sizing.firstEncodingThatFits([
    ///     ("png", { image.pngData() }),
    ///     ("jpg", { image.jpegData(compressionQuality: 0.8) }),
    /// ]) {
    ///     onPasteImage(data, format)
    /// } else {
    ///     onPasteImageTooLarge()
    /// }
    /// ```
    ///
    /// - Parameter encoders: `(label, encode)` pairs in priority order; `encode`
    ///   returns the encoded bytes, or `nil` if that encoding is unavailable.
    /// - Returns: The label and bytes of the first fitting candidate, or `nil` if
    ///   none fit.
    public func firstEncodingThatFits<Label>(
        _ encoders: [(label: Label, encode: () -> Data?)]
    ) -> (label: Label, data: Data)? {
        for candidate in encoders {
            guard let data = candidate.encode() else { continue }
            if fits(imageData: data) {
                return (candidate.label, data)
            }
        }
        return nil
    }
}
