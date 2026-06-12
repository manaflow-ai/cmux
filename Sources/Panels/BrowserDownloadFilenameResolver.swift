import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum BrowserDownloadHTTPStatusDecision: Equatable, Sendable {
    case allow
    case reject(statusCode: Int)
}

nonisolated struct BrowserDownloadFilenameResolver: Sendable {
    func httpStatusDecision(for response: URLResponse?) -> BrowserDownloadHTTPStatusDecision {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .allow
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            return .reject(statusCode: httpResponse.statusCode)
        }
        return .allow
    }

    func imageType(forImageData data: Data) -> UTType? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            return nil
        }
        return type
    }

    func imageType(forDownloadedFileAt fileURL: URL) -> UTType? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image) else {
            return nil
        }
        return type
    }

    func suggestedFilename(
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

    func suggestedFilename(
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

    func suggestedFilename(
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
