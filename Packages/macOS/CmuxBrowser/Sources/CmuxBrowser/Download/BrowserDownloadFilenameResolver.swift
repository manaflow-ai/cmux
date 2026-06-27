public import Foundation
public import UniformTypeIdentifiers
import ImageIO

/// Pure filename and download-policy resolution for the browser download paths.
///
/// Decides whether a navigation response should be forced to download, sanitizes
/// and image-corrects suggested filenames, and classifies HTTP status. Every
/// member is a pure function of its inputs with no live browser or webview state.
/// The localized fallback filename (used when no usable name can be derived) is
/// injected at construction so the string resolves in the app bundle; see the
/// app-side `init()` convenience that supplies it.
public struct BrowserDownloadFilenameResolver: Sendable {
    /// Localized fallback filename used when no usable name can be derived.
    private let defaultFilename: String

    /// Create a resolver with the localized fallback filename to use when no
    /// usable name can be derived from a response, URL, or suggested filename.
    public init(defaultFilename: String) {
        self.defaultFilename = defaultFilename
    }

    /// Whether the response's MIME type or `Content-Disposition` requires forcing
    /// a download rather than rendering inline.
    public func shouldForceDownload(
        mimeType: String?,
        contentDisposition: String?
    ) -> Bool {
        if Self.contentDispositionRequestsAttachment(contentDisposition) {
            return true
        }
        guard let normalizedMIMEType = Self.normalizedMIMEType(mimeType) else {
            return false
        }
        return Self.forceDownloadMIMETypes.contains(normalizedMIMEType)
    }

    /// The reason a navigation response should become a download, or `nil` when it
    /// can be shown inline. Returns `content-disposition`, `forceDownloadMIME`, or
    /// `cannotShowMIME`.
    public func navigationResponseDownloadReason(
        mimeType: String?,
        canShowMIMEType: Bool,
        contentDisposition: String?
    ) -> String? {
        if shouldForceDownload(mimeType: nil, contentDisposition: contentDisposition) {
            return "content-disposition"
        }
        if shouldForceDownload(mimeType: mimeType, contentDisposition: nil) {
            return "forceDownloadMIME"
        }
        return canShowMIMEType ? nil : "cannotShowMIME"
    }

    /// Whether the response's HTTP status permits saving the payload (2xx allows,
    /// any other HTTP status rejects, non-HTTP responses allow).
    public func httpStatusDecision(for response: URLResponse?) -> BrowserDownloadHTTPStatusDecision {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .allow
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            return .reject(statusCode: httpResponse.statusCode)
        }
        return .allow
    }

    /// The image UTType of raw bytes, or `nil` when the data is not a recognized image.
    public func imageType(forImageData data: Data) -> UTType? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            return nil
        }
        return type
    }

    /// The image UTType of a file on disk, or `nil` when the file is not a recognized image.
    public func imageType(forDownloadedFileAt fileURL: URL) -> UTType? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            return nil
        }
        return type
    }

    /// The sanitized filename to suggest in a save panel, image-corrected when an
    /// `imageType` is known so the extension matches the actual image format.
    public func suggestedFilename(
        suggestedFilename: String?,
        response: URLResponse?,
        sourceURL: URL,
        imageType: UTType?
    ) -> String {
        let fallbackURL = response?.url ?? sourceURL
        let filenameCandidate = suggestedFilename
            ?? response?.suggestedFilename
            ?? fallbackURL.lastPathComponent
        let safeCandidate = sanitizedFilename(filenameCandidate, fallbackURL: fallbackURL)

        guard let imageType else {
            return safeCandidate
        }

        return imageFilename(
            candidate: safeCandidate,
            imageType: imageType
        )
    }

    /// The sanitized filename to suggest, inferring the image type from `imageData`.
    public func suggestedFilename(
        suggestedFilename: String?,
        response: URLResponse?,
        sourceURL: URL,
        imageData: Data
    ) -> String {
        self.suggestedFilename(
            suggestedFilename: suggestedFilename,
            response: response,
            sourceURL: sourceURL,
            imageType: imageType(forImageData: imageData)
        )
    }

    /// The sanitized filename to suggest, inferring the image type from a downloaded file.
    public func suggestedFilename(
        suggestedFilename: String?,
        sourceURL: URL,
        imageFileURL: URL
    ) -> String {
        self.suggestedFilename(
            suggestedFilename: suggestedFilename,
            response: nil,
            sourceURL: sourceURL,
            imageType: imageType(forDownloadedFileAt: imageFileURL)
        )
    }

    /// The filename to suggest for a `data:` URL download, deriving an extension
    /// from the MIME type when no usable suggested filename is provided.
    public func suggestedFilenameForDataURL(
        mimeType: String?,
        suggestedFilename: String?
    ) -> String {
        if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return self.suggestedFilename(suggestedFilename: suggested, response: nil, sourceURL: URL(fileURLWithPath: "download"), imageType: nil)
        }
        let ext = ParsedDataURL.filenameExtension(forMIMEType: mimeType) ?? "bin"
        let base = (mimeType?.lowercased().hasPrefix("image/") ?? false) ? "image" : "download"
        return "\(base).\(ext)"
    }

    private func imageFilename(
        candidate: String,
        imageType: UTType
    ) -> String {
        if hasImageExtension(candidate, matching: imageType) {
            return candidate
        }

        let strippedCandidate = strippingNonImageExtensions(from: candidate, matching: imageType)
        if strippedCandidate != candidate {
            return strippedCandidate
        }

        let filenameExtension = preferredFilenameExtension(for: imageType)
        let base = baseNameByRemovingFinalExtension(from: candidate)
        return "\(base).\(filenameExtension)"
    }

    private func sanitizedFilename(_ raw: String, fallbackURL: URL?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmed as NSString).lastPathComponent
        let fromURL = fallbackURL?.lastPathComponent ?? ""
        let base = candidate.isEmpty ? fromURL : candidate
        let replaced = base.replacingOccurrences(of: ":", with: "-")
        let safe = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? defaultFilename : safe
    }

    private func strippingNonImageExtensions(from filename: String, matching imageType: UTType) -> String {
        var candidate = filename
        while !hasImageExtension(candidate, matching: imageType) {
            let next = baseNameByRemovingFinalExtension(from: candidate)
            guard next != candidate else { break }
            candidate = next
        }
        return hasImageExtension(candidate, matching: imageType) ? candidate : filename
    }

    private func baseNameByRemovingFinalExtension(from filename: String) -> String {
        let nsFilename = filename as NSString
        let base = nsFilename.deletingPathExtension
        return base.isEmpty ? defaultFilename : base
    }

    private static let forceDownloadMIMETypes: Set<String> = [
        "application/gzip",
        "application/octet-stream",
        "application/x-gzip",
        "application/x-zip-compressed",
        "application/zip",
        "text/csv",
    ]

    private static func normalizedMIMEType(_ mimeType: String?) -> String? {
        guard let rawType = mimeType?.split(separator: ";", maxSplits: 1).first else {
            return nil
        }
        let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func contentDispositionRequestsAttachment(_ contentDisposition: String?) -> Bool {
        guard let rawType = contentDisposition?.split(separator: ";", maxSplits: 1).first else {
            return false
        }
        return rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("attachment") == .orderedSame
    }

    private func hasImageExtension(_ filename: String, matching imageType: UTType) -> Bool {
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let extensionType = UTType(filenameExtension: pathExtension),
              extensionType.conforms(to: .image) else {
            return false
        }

        return extensionType.conforms(to: imageType) || imageType.conforms(to: extensionType)
    }

    private func preferredFilenameExtension(for imageType: UTType) -> String {
        if imageType.conforms(to: .jpeg) {
            return "jpg"
        }
        if let preferred = imageType.preferredFilenameExtension, !preferred.isEmpty {
            return preferred
        }
        return "img"
    }
}
