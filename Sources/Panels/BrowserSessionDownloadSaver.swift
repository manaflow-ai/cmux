import AppKit
import Foundation

@MainActor
final class BrowserSessionDownloadSaver {
    typealias DownloadStateNotifier = (Bool) -> Void
    typealias EventNotifier = ([String: Any]) -> Void
    typealias DebugLogger = (String) -> Void
    typealias FallbackRunner = (Selector?, AnyObject?, Any?, String, String) -> Void

    private let parentWindow: () -> NSWindow?
    private let notifyDownloadState: DownloadStateNotifier
    private let notifyEvent: EventNotifier
    private let debugLog: DebugLogger
    private let runFallback: FallbackRunner

    init(
        parentWindow: @escaping () -> NSWindow?,
        notifyDownloadState: @escaping DownloadStateNotifier,
        notifyEvent: @escaping EventNotifier,
        debugLog: @escaping DebugLogger,
        runFallback: @escaping FallbackRunner
    ) {
        self.parentWindow = parentWindow
        self.notifyDownloadState = notifyDownloadState
        self.notifyEvent = notifyEvent
        self.debugLog = debugLog
        self.runFallback = runFallback
    }

    func finish(
        data: Data,
        saveName: String,
        sourceURL: URL?,
        traceID: String,
        logCategory: String,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        failureFallbackReason: String?
    ) {
        let filenameResolver = BrowserDownloadFilenameResolver()
        let downloadID = UUID().uuidString
        notifyEvent(["type": "started", "download_id": downloadID, "filename": saveName])
        let handleWriteResult: (Result<URL, Error>, Bool) -> Void = { [weak self] result, shouldClearDownloadState in
            guard let self else { return }
            if shouldClearDownloadState { self.notifyDownloadState(false) }
            switch result {
            case .success(let destinationURL):
                self.debugLog("browser.ctxdl.\(logCategory) trace=\(traceID) stage=saveSuccess path=<redacted>")
                self.notifyEvent(["type": "saved", "download_id": downloadID, "filename": saveName, "path": destinationURL.path])
            case .failure(let error):
                self.debugLog("browser.ctxdl.\(logCategory) trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)")
                self.notifyEvent(["type": "failed", "download_id": downloadID, "filename": saveName, "error": error.localizedDescription])
                if let failureFallbackReason {
                    self.runFallback(fallbackAction, fallbackTarget, sender, traceID, failureFallbackReason)
                }
            }
        }

        if filenameResolver.shouldAskWhereToSaveDownloads() {
            promptForDestination(
                data: data,
                saveName: saveName,
                sourceURL: sourceURL,
                filenameResolver: filenameResolver,
                downloadID: downloadID,
                traceID: traceID,
                logCategory: logCategory,
                completion: { result in handleWriteResult(result, false) }
            )
            return
        }

        autoSaveInBackground(
            data,
            saveName: saveName,
            sourceURL: sourceURL,
            filenameResolver: filenameResolver,
            traceID: traceID,
            logCategory: logCategory,
            completion: { result in handleWriteResult(result, true) }
        )
    }

    private func promptForDestination(
        data: Data,
        saveName: String,
        sourceURL: URL?,
        filenameResolver: BrowserDownloadFilenameResolver,
        downloadID: String,
        traceID: String,
        logCategory: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = saveName
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = filenameResolver.downloadsDirectory()
        notifyDownloadState(false)
        notifyEvent(["type": "ready_to_save", "download_id": downloadID, "filename": saveName])
        debugLog("browser.ctxdl.\(logCategory) trace=\(traceID) stage=savePrompt shown=1 defaultName=<redacted>")
        let panelCompletion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else { return }
            guard result == .OK, let destURL = savePanel.url else {
                self.debugLog("browser.ctxdl.\(logCategory) trace=\(traceID) stage=savePrompt result=cancel")
                self.notifyEvent(["type": "cancelled", "download_id": downloadID, "filename": saveName])
                return
            }
            self.writeInBackground(data, destinationURL: destURL, sourceURL: sourceURL, replaceExisting: true, completion: completion)
        }
        if let parentWindow = parentWindow() {
            savePanel.beginSheetModal(for: parentWindow, completionHandler: panelCompletion)
        } else {
            savePanel.begin(completionHandler: panelCompletion)
        }
    }

    private func writeInBackground(
        _ data: Data,
        destinationURL: URL,
        sourceURL: URL?,
        replaceExisting: Bool,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                Self.write(data, to: destinationURL, sourceURL: sourceURL, replaceExisting: replaceExisting)
            }.value
            completion(result)
        }
    }

    private func autoSaveInBackground(
        _ data: Data,
        saveName: String,
        sourceURL: URL?,
        filenameResolver: BrowserDownloadFilenameResolver,
        traceID: String,
        logCategory: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                Self.autoSave(data, saveName: saveName, sourceURL: sourceURL, filenameResolver: filenameResolver)
            }.value
            if case .success = result {
                self.debugLog("browser.ctxdl.\(logCategory) trace=\(traceID) stage=autoSave path=<redacted>")
            }
            completion(result)
        }
    }

    private nonisolated static func autoSave(
        _ data: Data,
        saveName: String,
        sourceURL: URL?,
        filenameResolver: BrowserDownloadFilenameResolver
    ) -> Result<URL, Error> {
        Result {
            let fileManager = FileManager.default
            let directory = filenameResolver.downloadsDirectory(fileManager: fileManager)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            var lastCollisionError: Error?
            for _ in 0..<100 {
                let destinationURL = filenameResolver.uniqueDownloadDestination(
                    suggestedFilename: saveName,
                    in: directory,
                    fileManager: fileManager
                )
                do {
                    try writeWithoutReplacing(data, to: destinationURL, sourceURL: sourceURL, fileManager: fileManager)
                    return destinationURL
                } catch {
                    guard fileManager.fileExists(atPath: destinationURL.path) else { throw error }
                    lastCollisionError = error
                }
            }
            throw lastCollisionError ?? CocoaError(.fileWriteUnknown)
        }
    }

    private nonisolated static func write(
        _ data: Data,
        to destinationURL: URL,
        sourceURL: URL?,
        replaceExisting: Bool
    ) -> Result<URL, Error> {
        Result {
            if replaceExisting {
                try writeReplacing(data, to: destinationURL, sourceURL: sourceURL, fileManager: .default)
            } else {
                try writeWithoutReplacing(data, to: destinationURL, sourceURL: sourceURL, fileManager: .default)
            }
            return destinationURL
        }
    }

    private nonisolated static func writeReplacing(
        _ data: Data,
        to destinationURL: URL,
        sourceURL: URL?,
        fileManager: FileManager
    ) throws {
        let tempURL = temporaryURL(for: destinationURL)
        do {
            try data.write(to: tempURL, options: .atomic)
            try tempURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private nonisolated static func writeWithoutReplacing(
        _ data: Data,
        to destinationURL: URL,
        sourceURL: URL?,
        fileManager: FileManager
    ) throws {
        let tempURL = temporaryURL(for: destinationURL)
        do {
            try data.write(to: tempURL, options: .atomic)
            try tempURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private nonisolated static func temporaryURL(for destinationURL: URL) -> URL {
        destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".cmux-\(UUID().uuidString).download", isDirectory: false)
    }
}
