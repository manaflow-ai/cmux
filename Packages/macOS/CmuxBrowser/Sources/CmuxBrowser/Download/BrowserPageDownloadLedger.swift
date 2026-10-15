public import Foundation

/// Folds an engine's download reports (``BrowserPage``'s
/// `destinationForDownload` and ``BrowserPageEvent/downloadUpdated(_:)``)
/// into the browser panel's existing download flow, so a Chromium-engine
/// download reaches the same toolbar button, popover, notifications and
/// save step as a WebKit download.
///
/// Like WebKit downloads, an engine download is written to a temporary
/// file first (``Staged/temporaryURL``); when it completes, the panel moves
/// it into Downloads or asks where to save it, exactly as for WebKit.
/// Each report is applied at most once: a download ends once, and reports
/// for downloads the ledger never staged are ignored.
@MainActor
public final class BrowserPageDownloadLedger {
    /// A download with a temporary destination.
    public struct Staged: Equatable, Sendable {
        /// The panel's download id (the `download_id` of download events).
        public let downloadID: String
        /// The engine's id for the download.
        public let engineDownloadID: String
        /// Where the engine writes the file.
        public let temporaryURL: URL
        /// The sanitized file name to save under.
        public let suggestedFilename: String
        /// The URL downloaded (falls back to a file URL of the name, as WebKit's path does).
        public let sourceURL: URL
    }

    /// What a report means for the panel.
    public enum Transition: Equatable, Sendable {
        /// Bytes arrived.
        case progress(Staged, receivedBytes: Int64, expectedBytes: Int64?)
        /// The temporary file is complete: save it.
        case finished(Staged)
        /// The download was cancelled; its temporary file is gone or partial.
        case cancelled(Staged)
        /// The download failed.
        case failed(Staged, message: String)
    }

    private let temporaryDirectory: URL
    private let filenameResolver: BrowserDownloadFilenameResolver
    private let makeID: () -> String
    private var staged: [String: Staged] = [:]

    /// Creates a ledger.
    /// - Parameters:
    ///   - temporaryDirectory: Where downloads are written before saving (WebKit's `cmux-downloads` directory).
    ///   - filenameResolver: Sanitizes suggested file names.
    ///   - makeID: Makes a panel download id.
    public init(
        temporaryDirectory: URL,
        filenameResolver: BrowserDownloadFilenameResolver = BrowserDownloadFilenameResolver(),
        makeID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.filenameResolver = filenameResolver
        self.makeID = makeID
    }

    /// Downloads staged and not yet ended.
    public var activeCount: Int { staged.count }

    /// Chooses the temporary destination of a new download.
    /// - Parameter download: The engine's pending download.
    /// - Returns: The staged download, or the already staged one when the
    ///   engine asks again for the same download (Chromium resuming an
    ///   interrupted download keeps its file).
    public func stage(_ download: BrowserPageDownload) -> Staged {
        if let existing = staged[download.id] { return existing }
        let sourceURL = download.url ?? URL(fileURLWithPath: download.suggestedFilename ?? "download")
        let safeName = filenameResolver.suggestedFilename(
            suggestedFilename: download.suggestedFilename.flatMap { $0.isEmpty ? nil : $0 },
            response: nil,
            sourceURL: sourceURL,
            imageType: nil
        )
        let downloadID = makeID()
        let item = Staged(
            downloadID: downloadID,
            engineDownloadID: download.id,
            temporaryURL: temporaryDirectory.appendingPathComponent("\(downloadID)-\(safeName)", isDirectory: false),
            suggestedFilename: safeName,
            sourceURL: sourceURL
        )
        staged[download.id] = item
        return item
    }

    /// Applies one engine report.
    /// - Parameter download: The engine's latest description of the download.
    /// - Returns: What the panel does, or `nil` for nothing (unknown download, still pending).
    public func apply(_ download: BrowserPageDownload) -> Transition? {
        guard let item = staged[download.id] else { return nil }
        switch download.state {
        case .pending:
            return nil
        case .inProgress:
            return .progress(item, receivedBytes: download.receivedBytes, expectedBytes: download.expectedBytes)
        case .completed:
            staged[download.id] = nil
            return .finished(item)
        case .cancelled:
            staged[download.id] = nil
            return .cancelled(item)
        case .failed(let message):
            staged[download.id] = nil
            return .failed(item, message: message)
        }
    }

    /// Forgets every staged download (the page closed); returns them so the
    /// panel can end their activity and remove their temporary files.
    public func drain() -> [Staged] {
        let items = Array(staged.values)
        staged.removeAll()
        return items
    }
}
