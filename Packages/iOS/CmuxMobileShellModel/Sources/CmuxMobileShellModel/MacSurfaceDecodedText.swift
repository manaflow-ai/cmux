public import Foundation

/// The encoding a panel-file text decode resolved to.
public enum MacSurfaceTextEncoding: Equatable, Sendable {
    case utf8
    case isoLatin1
}

/// One decoded text payload and the encoding that produced it.
///
/// Mirrors the Mac markdown panel's decode order: strict UTF-8 first, then an
/// ISO-Latin-1 reinterpretation so legacy-encoded files still render as text
/// instead of failing into an unreadable state.
public struct MacSurfaceDecodedText: Equatable, Sendable {
    public let text: String
    public let encoding: MacSurfaceTextEncoding

    public init(text: String, encoding: MacSurfaceTextEncoding) {
        self.text = text
        self.encoding = encoding
    }

    /// Decodes panel file bytes as UTF-8, falling back to ISO-Latin-1.
    ///
    /// ISO-Latin-1 maps every byte to a character, so the fallback always
    /// succeeds and any byte payload decodes to text.
    public static func decoding(_ data: Data) -> MacSurfaceDecodedText {
        if let utf8 = String(data: data, encoding: .utf8) {
            return MacSurfaceDecodedText(text: utf8, encoding: .utf8)
        }
        let latin1 = String(data: data, encoding: .isoLatin1) ?? ""
        return MacSurfaceDecodedText(text: latin1, encoding: .isoLatin1)
    }
}
