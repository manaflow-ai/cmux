internal import Darwin
internal import Foundation

/// Decodes terminal clipboard C strings while bounding optional rich-text
/// representations.
///
/// Plain text remains unbounded because it is the user's requested payload.
/// Rich variants are optional pasteboard enhancements, so the decoder rejects
/// them before Swift allocates a string when they exceed the configured byte
/// budget.
public struct TerminalClipboardRepresentationDecoder: Sendable {
    /// The shared rich-text byte budget for ordinary and keyboard-copy writes.
    public static let defaultMaximumRichTextBytes = 2 * 1024 * 1024

    /// The largest non-plain C string that may be decoded.
    public let maximumRichTextBytes: Int

    /// Creates a decoder with a fixed rich-text byte budget.
    ///
    /// Negative budgets become zero. Values that would overflow the bounded
    /// C-string scan are clamped to `Int.max - 1`.
    ///
    /// - Parameter maximumRichTextBytes: Maximum UTF-8 bytes accepted for a
    ///   non-plain representation.
    public init(
        maximumRichTextBytes: Int = Self.defaultMaximumRichTextBytes
    ) {
        self.maximumRichTextBytes = min(
            max(maximumRichTextBytes, 0),
            Int.max - 1
        )
    }

    /// Decodes one runtime-owned clipboard C string.
    ///
    /// - Parameters:
    ///   - mimeType: MIME type for the data, or `nil` for legacy plain text.
    ///   - data: Null-terminated UTF-8 bytes owned by the runtime.
    /// - Returns: A decoded representation, or `nil` when optional rich text
    ///   exceeds ``maximumRichTextBytes``.
    public func decode(
        mimeType: String?,
        data: UnsafePointer<CChar>
    ) -> TerminalClipboardRepresentation? {
        let resolvedMIMEType = mimeType ?? "text/plain"
        let value: String
        if terminalClipboardMIMETypeIsPlain(mimeType) {
            value = String(cString: data)
        } else {
            let scanLimit = maximumRichTextBytes + 1
            let byteCount = strnlen(data, scanLimit)
            guard byteCount <= maximumRichTextBytes else { return nil }
            let bytes = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
            value = String(
                decoding: UnsafeBufferPointer(start: bytes, count: byteCount),
                as: UTF8.self
            )
        }
        return TerminalClipboardRepresentation(
            mimeType: resolvedMIMEType,
            string: value
        )
    }
}

private func terminalClipboardMIMETypeIsPlain(_ mimeType: String?) -> Bool {
    guard let mimeType else { return true }
    let base = mimeType.split(separator: ";", maxSplits: 1).first
        ?? Substring(mimeType)
    return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == "text/plain"
}
