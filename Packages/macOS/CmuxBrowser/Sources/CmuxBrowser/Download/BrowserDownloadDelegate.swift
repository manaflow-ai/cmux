public import Foundation
public import WebKit
public import AppKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// Handles WKDownload lifecycle by saving to a temp file synchronously, then
/// either auto-saving to Downloads or showing NSSavePanel after the download finishes.
///
/// The localized fallback filename used by the underlying
/// `BrowserDownloadFilenameResolver` is injected at construction so the string
/// resolves in the app bundle; see the app-side `init()` convenience.
///
/// `@MainActor`-isolated because `WKDownloadDelegate` is `WK_SWIFT_UI_ACTOR`
/// (`@MainActor`) in the WebKit SDK: WebKit delivers every download callback on
/// the main thread. The `NSLock` and `notifyOnMain` hop are preserved verbatim
/// from the app-target origin (defensive under the app's relaxed Swift 5
/// checking); on the main actor the lock is uncontended and `notifyOnMain`
/// always takes the synchronous main-thread branch, so runtime behavior is
/// byte-identical.
@MainActor
public final class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private struct DownloadState: Sendable {
        let downloadID: String
        let tempURL: URL
        let suggestedFilename: String
        let sourceURL: URL
    }

    /// Tracks active downloads keyed by WKDownload identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    /// Caller-supplied suggested-filename overrides (e.g. a scripted download
    /// that knows the intended name), keyed by WKDownload identity. Consumed
    /// once in `decideDestinationUsing` and cleared on teardown.
    private var suggestedFilenameOverrides: [ObjectIdentifier: String] = [:]
    private let activeDownloadsLock = NSLock()
    /// Localized fallback filename forwarded to the filename resolver.
    private let defaultFilename: String
    private nonisolated static let maxDownloadDestinationCollisionRetries = 100

    /// Called on the main thread when a download begins, with filename and download id.
    public var onDownloadStarted: ((String, String) -> Void)?
    /// Called on the main thread when a finished download is ready to present a save panel.
    public var onDownloadReadyToSave: ((String, String) -> Void)?
    /// Called on the main thread when a download is saved, with whether the activity count should end.
    public var onDownloadSaved: ((String, URL, Bool, String) -> Void)?
    /// Called on the main thread when a download prompt is cancelled.
    public var onDownloadCancelled: ((String, Bool, String) -> Void)?
    /// Called on the main thread when a download fails, with whether the activity count should end.
    public var onDownloadFailed: ((any Error, Bool, String?) -> Void)?
    /// The parent window used for the download save panel when downloads prompt for a destination.
    public var savePanelParentWindow: (() -> NSWindow?)?

    /// Create a download delegate with the localized fallback filename to use when
    /// no usable name can be derived for a download.
    public init(defaultFilename: String) {
        self.defaultFilename = defaultFilename
        super.init()
    }

    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Records a caller-supplied suggested filename to use for `download`,
    /// overriding WebKit's `suggestedFilename` (consumed once).
    public func setSuggestedFilenameOverride(_ suggestedFilename: String?, for download: WKDownload) {
        let trimmed = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return }
        activeDownloadsLock.lock()
        suggestedFilenameOverrides[ObjectIdentifier(download)] = trimmed
        activeDownloadsLock.unlock()
    }

    private func takeSuggestedFilenameOverride(for download: WKDownload) -> String? {
        activeDownloadsLock.lock()
        let filename = suggestedFilenameOverrides.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return filename
    }

    private func storeState(_ state: DownloadState, for download: WKDownload) {
        activeDownloadsLock.lock()
        activeDownloads[ObjectIdentifier(download)] = state
        suggestedFilenameOverrides.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
    }

    private func removeState(for download: WKDownload) -> DownloadState? {
        activeDownloadsLock.lock()
        let state = activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        suggestedFilenameOverrides.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadsLock.unlock()
        return state
    }

    /// Runs `action` synchronously on the main actor. The origin marshaled to
    /// main via `Thread.isMainThread`/`DispatchQueue.main.async`, but the
    /// `WKDownloadDelegate` callbacks are `@MainActor` (WebKit delivers them on
    /// the main thread), so the off-main branch was already unreachable; the
    /// synchronous call is behavior-identical.
    private func notifyOnMain(_ action: @MainActor () -> Void) {
        action()
    }

    private nonisolated static func moveTemporaryDownloadToDownloads(
        tempURL: URL,
        suggestedFilename: String,
        sourceURL: URL,
        filenameResolver: BrowserDownloadFilenameResolver,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = filenameResolver.downloadsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try tempURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
        var lastCollisionError: (any Error)?
        for _ in 0..<Self.maxDownloadDestinationCollisionRetries {
            let destinationURL = filenameResolver.uniqueDownloadDestination(
                suggestedFilename: suggestedFilename,
                in: directory,
                fileManager: fileManager
            )
            do {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                return destinationURL
            } catch {
                guard fileManager.fileExists(atPath: destinationURL.path) else {
                    throw error
                }
                lastCollisionError = error
            }
        }
        if let lastCollisionError {
            throw lastCollisionError
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func presentSavePanel(
        downloadID: String,
        tempURL: URL,
        suggestedFilename: String,
        sourceURL: URL,
        filenameResolver: BrowserDownloadFilenameResolver
    ) {
        onDownloadReadyToSave?(suggestedFilename, downloadID)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = suggestedFilename
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = filenameResolver.downloadsDirectory()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else { return }
            guard result == .OK, let destURL = savePanel.url else {
                try? FileManager.default.removeItem(at: tempURL)
                self.onDownloadCancelled?(suggestedFilename, false, downloadID)
                return
            }
            do {
                try tempURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                }
                try? destURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)
                self.onDownloadSaved?(suggestedFilename, destURL, false, downloadID)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                self.onDownloadFailed?(error, false, downloadID)
            }
        }
        if let parentWindow = savePanelParentWindow?() {
            savePanel.beginSheetModal(for: parentWindow, completionHandler: completion)
        } else {
            savePanel.begin(completionHandler: completion)
        }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        // Save to a temp file: return synchronously so WebKit is never blocked.
        let filenameResolver = BrowserDownloadFilenameResolver(defaultFilename: defaultFilename)
        if case .reject = filenameResolver.httpStatusDecision(for: response) {
            _ = removeState(for: download)
            completionHandler(nil)
            return
        }
        // A caller-supplied override (e.g. a scripted download) wins over
        // WebKit's suggested filename.
        let effectiveSuggestedFilename = takeSuggestedFilenameOverride(for: download) ?? suggestedFilename
        let sourceURL = response.url ?? URL(fileURLWithPath: effectiveSuggestedFilename)
        let safeFilename = filenameResolver.suggestedFilename(
            suggestedFilename: effectiveSuggestedFilename,
            response: response,
            sourceURL: sourceURL,
            imageType: nil
        )
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        let downloadID = UUID().uuidString
        try? FileManager.default.removeItem(at: destURL)
        storeState(
            DownloadState(
                downloadID: downloadID,
                tempURL: destURL,
                suggestedFilename: safeFilename,
                sourceURL: sourceURL
            ),
            for: download
        )
        notifyOnMain { [weak self] in
            self?.onDownloadStarted?(safeFilename, downloadID)
        }
        #if DEBUG
        CMUXDebugLog.logDebugEvent("download.decideDestination file=<redacted>")
        #endif
        completionHandler(destURL)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            #if DEBUG
            CMUXDebugLog.logDebugEvent("download.finished missing-state")
            #endif
            return
        }
        #if DEBUG
        CMUXDebugLog.logDebugEvent("download.finished file=<redacted>")
        #endif
        let filenameResolver = BrowserDownloadFilenameResolver(defaultFilename: defaultFilename)
        Task { @MainActor in
            let imageType = await Task.detached(priority: .utility) {
                filenameResolver.imageType(forDownloadedFileAt: info.tempURL)
            }.value
            let suggestedFilename = filenameResolver.suggestedFilename(
                suggestedFilename: info.suggestedFilename,
                response: nil,
                sourceURL: info.sourceURL,
                imageType: imageType
            )

            if filenameResolver.shouldAskWhereToSaveDownloads() {
                self.presentSavePanel(
                    downloadID: info.downloadID,
                    tempURL: info.tempURL,
                    suggestedFilename: suggestedFilename,
                    sourceURL: info.sourceURL,
                    filenameResolver: filenameResolver
                )
                return
            }

            let saveResult = await Task.detached(priority: .utility) {
                Result {
                    try Self.moveTemporaryDownloadToDownloads(
                        tempURL: info.tempURL,
                        suggestedFilename: suggestedFilename,
                        sourceURL: info.sourceURL,
                        filenameResolver: filenameResolver
                    )
                }
            }.value
            switch saveResult {
            case .success(let destinationURL):
                self.onDownloadSaved?(suggestedFilename, destinationURL, true, info.downloadID)
                #if DEBUG
                CMUXDebugLog.logDebugEvent("download.saved path=<redacted>")
                #endif
            case .failure(let error):
                try? FileManager.default.removeItem(at: info.tempURL)
                self.onDownloadFailed?(error, true, info.downloadID)
            }
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let downloadID: String?
        if let info = removeState(for: download) {
            try? FileManager.default.removeItem(at: info.tempURL)
            downloadID = info.downloadID
        } else {
            downloadID = nil
        }
        notifyOnMain { [weak self] in
            self?.onDownloadFailed?(error, true, downloadID)
        }
        #if DEBUG
        CMUXDebugLog.logDebugEvent("download.failed error=\(error.localizedDescription)")
        #endif
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}
