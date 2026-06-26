public import Foundation
import UniformTypeIdentifiers

/// A decoded `data:` URL payload: the raw bytes plus the optional MIME type
/// declared in the URL header. Constructed by parsing a `data:` URL; returns
/// `nil` for any URL that is not a well-formed data URL.
public struct ParsedDataURL: Sendable {
    /// The decoded payload bytes.
    public let data: Data
    /// The MIME type declared in the data URL header, if any.
    public let mimeType: String?

    /// Decode a `data:` URL into its payload bytes and MIME type, or `nil` when
    /// the URL is not a valid data URL (wrong scheme, missing comma, or undecodable
    /// base64/percent-encoded payload).
    public init?(dataURL url: URL) {
        let absolute = url.absoluteString
        guard absolute.hasPrefix("data:"),
              let commaIndex = absolute.firstIndex(of: ",") else {
            return nil
        }

        let headerStart = absolute.index(absolute.startIndex, offsetBy: 5)
        let header = String(absolute[headerStart..<commaIndex])
        let payloadStart = absolute.index(after: commaIndex)
        let payload = String(absolute[payloadStart...])

        let segments = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let mimeType = segments.first.flatMap { $0.isEmpty ? nil : $0 }
        let isBase64 = segments.dropFirst().contains { $0.caseInsensitiveCompare("base64") == .orderedSame }

        if isBase64 {
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            self.data = data
            self.mimeType = mimeType
            return
        }

        guard let decoded = payload.removingPercentEncoding else { return nil }
        self.data = Data(decoded.utf8)
        self.mimeType = mimeType
    }

    /// The preferred filename extension for a MIME type, or `nil` when none is
    /// known. Prefers the system `UTType` mapping and falls back to a small table
    /// of common image and text types.
    public static func filenameExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        if #available(macOS 11.0, *) {
            if let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension, !preferred.isEmpty {
                return preferred
            }
        }
        switch mimeType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "text/html":
            return "html"
        case "text/plain":
            return "txt"
        default:
            return nil
        }
    }
}
