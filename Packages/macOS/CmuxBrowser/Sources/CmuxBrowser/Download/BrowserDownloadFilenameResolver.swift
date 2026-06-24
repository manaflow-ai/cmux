public import Foundation
internal import ImageIO
public import UniformTypeIdentifiers

/// Resolves safe on-disk filenames for browser downloads and classifies which
/// responses should be downloaded at all.
///
/// Lifted byte-faithfully out of the app target so the WebKit download path
/// (`BrowserDownloadDelegate`) and the navigation-response download policy live
/// together in `CmuxBrowser`. A pure value type with no stored state, so it is
/// `Sendable` and `nonisolated`: every method is a deterministic transform over
/// its arguments plus `FileManager`/`ImageIO` reads, callable from the
/// nonisolated download-delegate callbacks.
///
/// A real instance value type constructed at the call site
/// (`BrowserDownloadFilenameResolver()`), not a static-only namespace: its public
/// surface is instance methods, satisfying the refactor's "no static-method
/// utility types" discipline.
public nonisolated struct BrowserDownloadFilenameResolver: Sendable {
    /// Creates a filename resolver.
    public init() {}

    /// Whether a response with the given MIME type / `Content-Disposition` should
    /// be forced to download rather than displayed inline.
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

    /// A short reason string when a navigation response should become a download,
    /// or `nil` when the response can be shown inline.
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

    /// Whether the response's HTTP status permits saving the download.
    public func httpStatusDecision(for response: URLResponse?) -> BrowserDownloadHTTPStatusDecision {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .allow
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            return .reject(statusCode: httpResponse.statusCode)
        }
        return .allow
    }

    /// The image `UTType` of the given raw data, or `nil` if it is not an image.
    public func imageType(forImageData data: Data) -> UTType? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            return nil
        }
        return type
    }

    /// The image `UTType` of the file at `fileURL`, or `nil` if it is not an image.
    public func imageType(forDownloadedFileAt fileURL: URL) -> UTType? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            return nil
        }
        return type
    }

    /// A sanitized download filename derived from the suggested name, response,
    /// source URL, and (optional) detected image type.
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

    /// A sanitized download filename, detecting the image type from raw data.
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

    /// A sanitized download filename, detecting the image type from a file on disk.
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

    private var defaultFilename: String {
        String(localized: "browser.download.defaultFilename", defaultValue: "download")
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
