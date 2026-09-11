public import Foundation

/// Decodes panel file bytes for native text rendering on the phone.
///
/// Mirrors the Mac markdown panel's decode order: strict UTF-8 first, then an
/// ISO-Latin-1 reinterpretation so legacy-encoded files still render as text
/// instead of failing into an unreadable state.
public enum MacSurfaceTextDecoder {
    /// The encoding a decode resolved to.
    public enum Encoding: Equatable, Sendable {
        case utf8
        case isoLatin1
    }

    /// One decoded text payload and the encoding that produced it.
    public struct DecodedText: Equatable, Sendable {
        public let text: String
        public let encoding: Encoding

        public init(text: String, encoding: Encoding) {
            self.text = text
            self.encoding = encoding
        }
    }

    /// Decodes file bytes as UTF-8, falling back to ISO-Latin-1.
    ///
    /// ISO-Latin-1 maps every byte to a character, so the fallback always
    /// succeeds and any byte payload decodes to text.
    public static func decode(_ data: Data) -> DecodedText {
        if let utf8 = String(data: data, encoding: .utf8) {
            return DecodedText(text: utf8, encoding: .utf8)
        }
        let latin1 = String(data: data, encoding: .isoLatin1) ?? ""
        return DecodedText(text: latin1, encoding: .isoLatin1)
    }
}
