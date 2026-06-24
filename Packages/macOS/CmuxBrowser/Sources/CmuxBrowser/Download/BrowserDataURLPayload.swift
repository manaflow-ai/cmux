public import Foundation
internal import UniformTypeIdentifiers

/// The decoded contents of a `data:` URL: its raw bytes plus the optional MIME
/// type declared in the URL header.
///
/// Lifted byte-faithfully out of the app target so the browser context-menu
/// download/copy paths (image detection, save-panel naming, pasteboard copy) and
/// the on-disk filename derivation in `BrowserDownloadFilenameResolver` live
/// together in `CmuxBrowser`. A pure value type with no stored reference state, so
/// it is `Sendable` and `nonisolated`: parsing and filename derivation are
/// deterministic transforms over the URL plus `UTType`/Foundation reads.
///
/// A real instance value type with a failable `init?(url:)`, not a static-only
/// namespace of parsing utilities: callers construct
/// `BrowserDataURLPayload(url:)` and read `data`/`mimeType` or call
/// `suggestedFilename(forSuggestedFilename:)`, satisfying the refactor's "no
/// static-method utility types" discipline.
public nonisolated struct BrowserDataURLPayload: Sendable {
    /// The decoded payload bytes of the `data:` URL.
    public let data: Data

    /// The MIME type declared in the `data:` URL header, or `nil` when absent.
    public let mimeType: String?

    /// Parses a `data:` URL into its decoded bytes and MIME type.
    ///
    /// Returns `nil` when the URL is not a `data:` URL, has no `,` separator, or
    /// fails base64 / percent-decoding. Handles both base64 (`;base64,`) and
    /// percent-encoded payloads, matching the legacy app-target parser exactly.
    public init?(url: URL) {
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

    /// A safe save-panel filename for this payload.
    ///
    /// When a non-empty suggested filename is provided, it is sanitized through
    /// `BrowserDownloadFilenameResolver`. Otherwise a name is synthesized from the
    /// MIME type (e.g. `image.png`, `download.bin`).
    public func suggestedFilename(forSuggestedFilename suggestedFilename: String?) -> String {
        if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return BrowserDownloadFilenameResolver().suggestedFilename(
                suggestedFilename: suggested,
                response: nil,
                sourceURL: URL(fileURLWithPath: "download"),
                imageType: nil
            )
        }
        let ext = filenameExtension ?? "bin"
        let base = (mimeType?.lowercased().hasPrefix("image/") ?? false) ? "image" : "download"
        return "\(base).\(ext)"
    }

    /// The preferred file extension for this payload's MIME type, or `nil` when it
    /// cannot be determined.
    private var filenameExtension: String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        if let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension, !preferred.isEmpty {
            return preferred
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
