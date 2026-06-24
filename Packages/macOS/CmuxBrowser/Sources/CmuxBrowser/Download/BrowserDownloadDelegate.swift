public import WebKit
public import Foundation
internal import AppKit

/// Handles `WKDownload` lifecycle by saving to a temp file synchronously (no UI
/// during WebKit callbacks), then showing an `NSSavePanel` after the download
/// finishes.
///
/// Lifted byte-faithfully out of the app target. The download lifecycle is driven
/// entirely by WebKit callbacks (some of which arrive off the main thread), so the
/// active-download bookkeeping is guarded by an `NSLock` exactly as in the legacy
/// body and surfaced to the owner through three injected closures
/// (``onDownloadStarted``/``onDownloadReadyToSave``/``onDownloadFailed``). Those
/// closures, the panel presentation, and the post-finish save remain identical to
/// the original `BrowserPanel` implementation.
///
/// `@unchecked Sendable`: the only mutable state is `activeDownloads`, which is
/// only ever read or written while `activeDownloadsLock` is held, mirroring the
/// legacy lock-guarded access faithfully.
public final class BrowserDownloadDelegate: NSObject, WKDownloadDelegate, @unchecked Sendable {
    private struct DownloadState: Sendable {
        let tempURL: URL
        let suggestedFilename: String
        let sourceURL: URL
    }

    /// Tracks active downloads keyed by `WKDownload` identity.
    private var activeDownloads: [ObjectIdentifier: DownloadState] = [:]
    private let activeDownloadsLock = NSLock()

    /// Invoked on the main thread when a download begins, with its safe filename.
    public var onDownloadStarted: ((String) -> Void)?

    /// Invoked on the main actor when a finished download is ready to be saved
    /// (immediately before the `NSSavePanel` is presented).
    public var onDownloadReadyToSave: (() -> Void)?

    /// Invoked on the main thread when a download fails, with the error.
    public var onDownloadFailed: ((any Error) -> Void)?

    /// Optional debug-log sink, invoked with the former `#if DEBUG`-guarded
    /// `cmuxDebugLog` trace messages. `nil` in release builds so the traces are
    /// compiled out at the wiring site, exactly as before.
    public var logSink: (@Sendable (String) -> Void)?

    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Creates a download delegate. Callers assign the closure properties after
    /// construction.
    public override init() {
        super.init()
    }

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

    private func notifyOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Save to a temp file — return synchronously so WebKit is never blocked.
        let filenameResolver = BrowserDownloadFilenameResolver()
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
        logSink?("download.decideDestination file=\(safeFilename)")
        completionHandler(destURL)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let info = removeState(for: download) else {
            logSink?("download.finished missing-state")
            return
        }
        logSink?("download.finished file=\(info.suggestedFilename)")
        let filenameResolver = BrowserDownloadFilenameResolver()
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
        logSink?("download.failed error=\(error.localizedDescription)")
        NSLog("BrowserPanel download failed: %@", error.localizedDescription)
    }
}
