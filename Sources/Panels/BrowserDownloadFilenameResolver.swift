import Foundation
import CoreServices
import ImageIO
import CmuxSettings
import UniformTypeIdentifiers

nonisolated struct BrowserDownloadFilenameResolver: Sendable {
    private static let maxFilenameCollisionAttempts = 100

    func shouldForceDownload(
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

    func navigationResponseDownloadReason(
        mimeType: String?,
        canShowMIMEType: Bool,
        contentDisposition: String?,
        isForMainFrame: Bool = true,
        allowsSubframeDownload: Bool = false,
        isUserActivatedPreviouslyRenderedSubframePDF: Bool = false
    ) -> String? {
        if !isForMainFrame,
           isUserActivatedPreviouslyRenderedSubframePDF,
           isPDFMIMEType(mimeType) {
            return "subframePDFUserAction"
        }
        let canUseExplicitDownloadSignals = isForMainFrame || allowsSubframeDownload
        if canUseExplicitDownloadSignals,
           shouldForceDownload(mimeType: nil, contentDisposition: contentDisposition) {
            return "content-disposition"
        }
        if canUseExplicitDownloadSignals,
           shouldForceDownload(mimeType: mimeType, contentDisposition: nil) {
            return "forceDownloadMIME"
        }
        guard isForMainFrame else { return nil }
        return canShowMIMEType ? nil : "cannotShowMIME"
    }

    func shouldPrintPDFAfterLoad(mimeType: String?, responseURL: URL?, isForMainFrame: Bool) -> Bool {
        guard isForMainFrame, isPDFMIMEType(mimeType) else { return false }
        guard let components = responseURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return false
        }
        return components.queryItems?.contains {
            $0.name.caseInsensitiveCompare("print") == .orderedSame &&
                (($0.value ?? "").caseInsensitiveCompare("true") == .orderedSame || $0.value == "1")
        } == true
    }

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

    func shouldAskWhereToSaveDownloads(defaults: UserDefaults = .standard) -> Bool {
        let setting = SettingCatalog().browser.askWhereToSaveDownloads
        if defaults.object(forKey: setting.userDefaultsKey) == nil {
            return setting.defaultValue
        }
        return defaults.bool(forKey: setting.userDefaultsKey)
    }

    func downloadsDirectory(fileManager: FileManager = .default) -> URL {
        if let directory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return directory
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    func uniqueDownloadDestination(
        suggestedFilename: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let safeFilename = sanitizedFilename(suggestedFilename, fallbackURL: nil)
        let candidate = directory.appendingPathComponent(safeFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let nsFilename = safeFilename as NSString
        let base = nsFilename.deletingPathExtension.isEmpty ? defaultFilename : nsFilename.deletingPathExtension
        let ext = nsFilename.pathExtension
        var index = 1
        while index <= Self.maxFilenameCollisionAttempts {
            let dedupedName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(dedupedName, isDirectory: false)
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }

        let uuid = UUID().uuidString
        let fallbackName = ext.isEmpty ? "\(base)-\(uuid)" : "\(base)-\(uuid).\(ext)"
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
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

    private func isPDFMIMEType(_ mimeType: String?) -> Bool {
        Self.normalizedMIMEType(mimeType) == "application/pdf"
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

extension URL {
    func cmuxApplyWebDownloadQuarantine(sourceURL: URL?) throws {
        guard let sourceURL,
              !sourceURL.isFileURL else {
            return
        }

        var quarantineProperties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
            kLSQuarantineAgentNameKey as String: Self.cmuxDownloadQuarantineAgentName(),
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            quarantineProperties[kLSQuarantineAgentBundleIdentifierKey as String] = bundleIdentifier
        }
        if let sanitizedSourceURL = Self.cmuxSanitizedDownloadSourceURL(sourceURL) {
            quarantineProperties[kLSQuarantineDataURLKey as String] = sanitizedSourceURL
            quarantineProperties[kLSQuarantineOriginURLKey as String] = sanitizedSourceURL
        }

        var resourceValues = URLResourceValues()
        resourceValues.quarantineProperties = quarantineProperties
        var fileURL = self
        try fileURL.setResourceValues(resourceValues)
    }

    private static func cmuxDownloadQuarantineAgentName() -> String {
        let candidate = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "cmux" : trimmed
    }

    private static func cmuxSanitizedDownloadSourceURL(_ sourceURL: URL) -> URL? {
        let scheme = sourceURL.scheme?.lowercased()
        guard scheme == "http" || scheme == "https",
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
