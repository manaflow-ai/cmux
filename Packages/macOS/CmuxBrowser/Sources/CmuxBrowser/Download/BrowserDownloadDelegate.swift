public import Foundation
public import WebKit
internal import AppKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// Handles WKDownload lifecycle by saving to a temp file synchronously (no UI
/// during WebKit callbacks), then showing NSSavePanel after the download finishes.
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
        let tempURL: URL
        let suggestedFilename: String
        let sourceURL: URL
    }

    /// Tracks active downloads keyed by WKDownload identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    private let activeDownloadsLock = NSLock()
    /// Localized fallback filename forwarded to the filename resolver.
    private let defaultFilename: String
    /// Called on the main thread when a download begins, with its resolved filename.
    public var onDownloadStarted: ((String) -> Void)?
    /// Called on the main thread when a finished download is ready to present a save panel.
    public var onDownloadReadyToSave: (() -> Void)?
    /// Called on the main thread when a download fails.
    public var onDownloadFailed: ((any Error) -> Void)?

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

    private func storeState(_ state: DownloadState, for download: WKDownload) {
        activeDownloadsLock.lock()
        activeDownloads[ObjectIdentifier(download)] = state
        activeDownloadsLock.unlock()
    }

    private func removeState(for download: WKDownload) -> DownloadState? {
        activeDownloadsLock.lock()
        let state = activeDownloads.removeValue(forKey: ObjectIdentifier(download))
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

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        // Save to a temp file — return synchronously so WebKit is never blocked.
        let filenameResolver = BrowserDownloadFilenameResolver(defaultFilename: defaultFilename)
        if case .reject = filenameResolver.httpStatusDecision(for: response) {
            completionHandler(nil)
            return
        }
        let sourceURL = response.url ?? URL(fileURLWithPath: suggestedFilename)
        let safeFilename = filenameResolver.suggestedFilename(suggestedFilename: suggestedFilename, response: response, sourceURL: sourceURL, imageType: nil)
        let tempFilename = "\(UUID().uuidString)-\(safeFilename)"
        let destURL = Self.tempDir.appendingPathComponent(tempFilename, isDirectory: false)
        try? FileManager.default.removeItem(at: destURL)
        storeState(DownloadState(tempURL: destURL, suggestedFilename: safeFilename, sourceURL: sourceURL), for: download)
        notifyOnMain { [weak self] in
            self?.onDownloadStarted?(safeFilename)
        }
        #if DEBUG
        CMUXDebugLog.logDebugEvent("download.decideDestination file=\(safeFilename)")
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
        CMUXDebugLog.logDebugEvent("download.finished file=\(info.suggestedFilename)")
        #endif
        let filenameResolver = BrowserDownloadFilenameResolver(defaultFilename: defaultFilename)
        Task { @MainActor in
            let imageType = await Task.detached(priority: .utility) {
                filenameResolver.imageType(forDownloadedFileAt: info.tempURL)
            }.value
            self.onDownloadReadyToSave?()
            let suggestedFilename = filenameResolver.suggestedFilename(suggestedFilename: info.suggestedFilename, response: nil, sourceURL: info.sourceURL, imageType: imageType)
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = suggestedFilename
            savePanel.canCreateDirectories = true
            savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            savePanel.begin { result in
                guard result == .OK, let destURL = savePanel.url else {
                    try? FileManager.default.removeItem(at: info.tempURL)
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        _ = try FileManager.default.replaceItemAt(destURL, withItemAt: info.tempURL)
                    } else {
                        try FileManager.default.moveItem(at: info.tempURL, to: destURL)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: info.tempURL)
                }
            }
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        if let info = removeState(for: download) {
            try? FileManager.default.removeItem(at: info.tempURL)
        }
        notifyOnMain { [weak self] in
            self?.onDownloadFailed?(error)
        }
        #if DEBUG
        CMUXDebugLog.logDebugEvent("download.failed error=\(error.localizedDescription)")
        #endif
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}
