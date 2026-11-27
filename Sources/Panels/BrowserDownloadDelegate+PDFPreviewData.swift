import Foundation
import CmuxBrowser
import UniformTypeIdentifiers

extension BrowserDownloadDelegate {
    @MainActor
    func savePDFPreviewData(
        _ data: Data,
        suggestedFilename: String?,
        mimeType: String?,
        sourceURL: URL?,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        guard !data.isEmpty else { return }
        let filenameResolver = BrowserDownloadFilenameResolver()
        let resolvedSourceURL = sourceURL ?? URL(fileURLWithPath: "document.pdf")
        let trimmedSuggestedFilename = suggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var safeFilename = filenameResolver.suggestedFilename(
            suggestedFilename: trimmedSuggestedFilename?.isEmpty == false ? trimmedSuggestedFilename : nil,
            response: nil,
            sourceURL: resolvedSourceURL,
            imageType: nil
        )
        if (safeFilename as NSString).pathExtension.isEmpty {
            safeFilename += ".\(Self.filenameExtension(for: mimeType))"
        }
        let downloadID = UUID().uuidString
        onDownloadStarted?(safeFilename, downloadID)
        let tempURL = Self.tempDir.appendingPathComponent("\(downloadID)-\(safeFilename)", isDirectory: false)
        Task { @MainActor in
            let writeResult = await Task.detached(priority: .utility) {
                Result {
                    try? FileManager.default.removeItem(at: tempURL)
                    try data.write(to: tempURL, options: .atomic)
                    return tempURL
                }
            }.value
            switch writeResult {
            case .success:
                if filenameResolver.shouldAskWhereToSaveDownloads(defaults: defaults) {
                    self.presentSavePanel(
                        downloadID: downloadID,
                        tempURL: tempURL,
                        suggestedFilename: safeFilename,
                        sourceURL: resolvedSourceURL,
                        filenameResolver: filenameResolver
                    )
                    return
                }
                let saveResult = await Task.detached(priority: .utility) {
                    Result {
                        try Self.moveTemporaryDownloadToDownloads(
                            tempURL: tempURL,
                            suggestedFilename: safeFilename,
                            sourceURL: resolvedSourceURL,
                            filenameResolver: filenameResolver,
                            fileManager: fileManager
                        )
                    }
                }.value
                switch saveResult {
                case .success(let destinationURL):
                    self.onDownloadSaved?(safeFilename, destinationURL, true, downloadID)
                case .failure(let error):
                    try? FileManager.default.removeItem(at: tempURL)
                    self.onDownloadFailed?(error, true, downloadID)
                }
            case .failure(let error):
                self.onDownloadFailed?(error, true, downloadID)
            }
        }
    }

    private nonisolated static func filenameExtension(for mimeType: String?) -> String {
        let normalizedMIMEType = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedMIMEType?.caseInsensitiveCompare("application/pdf") == .orderedSame {
            return "pdf"
        }
        guard let normalizedMIMEType,
              let preferredExtension = UTType(mimeType: String(normalizedMIMEType))?.preferredFilenameExtension,
              !preferredExtension.isEmpty else {
            return "pdf"
        }
        return preferredExtension
    }
}
