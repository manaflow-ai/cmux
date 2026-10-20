public import Foundation
public import Observation

/// A download in progress or completed, the same for both engines: WebKit
/// mirrors a `WKDownload` into it, Chromium the shim's download events
/// (`CEFDownloads`). The App's downloads list holds these.
@Observable
public final class BrowserDownload: Identifiable {
    public enum Status: Hashable, Sendable {
        case inProgress
        case finished
        case failed(String)
        case cancelled
        /// Refused before it started; the text says why (localized).
        case blocked(String)
    }

    public let id = UUID()
    public let sourceURL: URL?
    public internal(set) var filename: String
    public internal(set) var destination: URL?
    /// `0...1`, or nil when the size is unknown.
    public internal(set) var fraction: Double?
    /// Bytes so far, the total (nil when unknown) and the current speed in
    /// bytes per second, when the engine reports them (Chromium).
    public internal(set) var receivedBytes: Int64 = 0
    public internal(set) var totalBytes: Int64?
    public internal(set) var bytesPerSecond: Int64?
    public internal(set) var isPaused = false
    public internal(set) var status: Status = .inProgress
    /// The site (origin) whose automatic-downloads setting blocked this
    /// download; its Site settings change the choice. Nil otherwise.
    public internal(set) var blockedSite: String?

    /// Where the file is written and lands (`BrowserDownloadPlacement`).
    @ObservationIgnored
    var placement: BrowserDownloadPlacement?
    @ObservationIgnored
    var cancelHandler: (() -> Void)?
    /// Pause and resume, when the engine can.
    @ObservationIgnored
    var pauseHandler: ((Bool) -> Void)?
    /// Starts the same download again as a new one (Retry), when its engine
    /// can: a web link, from a tab still open. False when it could not start.
    @ObservationIgnored
    var retryHandler: (() -> Bool)?
    @ObservationIgnored
    private var finishHandlers: [(BrowserDownload) -> Void] = []
    @ObservationIgnored
    private let quarantine: (URL, URL?) throws -> Void

    /// The name the page suggested (sanitized), before a free file name was
    /// picked: what an agent's `download.suggestedFilename()` returns.
    public internal(set) var suggestedFilename: String

    /// The engine knows the page's suggested name (`named()`); WebKit
    /// learns it only when it picks the destination.
    public private(set) var isNamed: Bool
    private var namedHandlers: [(BrowserDownload) -> Void] = []

    public init(sourceURL: URL?, filename: String, suggestedFilename: String? = nil, named: Bool = true,
                quarantine: @escaping (URL, URL?) throws -> Void = { try BrowserDownloadPolicy.quarantine($0, source: $1) }) {
        self.sourceURL = sourceURL
        self.filename = filename
        self.suggestedFilename = suggestedFilename ?? filename
        isNamed = named
        self.quarantine = quarantine
    }

    /// Runs `handler` once the download is named (at once when it is).
    public func onNamed(_ handler: @escaping (BrowserDownload) -> Void) {
        guard !isNamed else { return handler(self) }
        namedHandlers.append(handler)
    }

    /// The engine set the suggested name; later calls do nothing.
    func named() {
        guard !isNamed else { return }
        isNamed = true
        let handlers = namedHandlers
        namedHandlers = []
        handlers.forEach { $0(self) }
    }

    /// A download refused before it started, listed blocked: `reason`
    /// says why, `site` is the site whose setting blocked it. Both engines
    /// list their refused automatic downloads through this.
    static func blocked(sourceURL: URL?, suggestedName: String, site: String?, reason: String) -> BrowserDownload {
        let item = BrowserDownload(sourceURL: sourceURL, filename: DownloadDestination.sanitizedFilename(suggestedName))
        item.blockedSite = site
        item.complete(.blocked(reason))
        return item
    }

    /// A download that ended in an earlier run, as the Downloads list kept
    /// it: nothing runs on its file, and it cannot pause or retry.
    public static func ended(sourceURL: URL?, filename: String, destination: URL?, status: Status,
                             receivedBytes: Int64, totalBytes: Int64?) -> BrowserDownload {
        let item = BrowserDownload(sourceURL: sourceURL, filename: filename)
        item.destination = destination
        item.receivedBytes = receivedBytes
        item.totalBytes = totalBytes
        if status == .finished { item.fraction = 1 }
        item.status = status == .inProgress ? .cancelled : status
        return item
    }

    public var canPause: Bool { pauseHandler != nil && status == .inProgress }

    /// A failed or cancelled download its engine can start again.
    public var canRetry: Bool {
        switch status {
        case .failed, .cancelled: retryHandler != nil
        case .inProgress, .finished, .blocked: false
        }
    }

    /// Starts this download again; the new one is a new `BrowserDownload`
    /// (the engine's `.download` intent). False when it could not start.
    @discardableResult
    public func retry() -> Bool {
        guard canRetry, let retryHandler else { return false }
        return retryHandler()
    }

    public func cancel() {
        guard status == .inProgress else { return }
        cancelHandler?()
        complete(.cancelled)
    }

    public func setPaused(_ paused: Bool) {
        guard canPause, paused != isPaused else { return }
        pauseHandler?(paused)
    }

    /// Runs `handler` once the download ends (now, if it already has).
    public func onFinish(_ handler: @escaping (BrowserDownload) -> Void) {
        guard status == .inProgress else { return handler(self) }
        finishHandlers.append(handler)
    }

    /// Progress from the engine.
    func update(received: Int64, total: Int64?, bytesPerSecond: Int64? = nil, paused: Bool = false) {
        guard status == .inProgress else { return }
        receivedBytes = received
        totalBytes = total
        self.bytesPerSecond = bytesPerSecond
        isPaused = paused
        fraction = total.flatMap { $0 > 0 ? min(Double(received) / Double($0), 1) : nil }
    }

    /// The download ended. Both engines end every download here, so a
    /// finished file is quarantined while it still has its temporary name,
    /// then moves into place (`BrowserDownloadPlacement.finish`). A failed
    /// quarantine or move fails the download and leaves no file; a failed or
    /// cancelled download also leaves no file, and only the first end counts.
    func complete(_ end: Status) {
        guard status == .inProgress, end != .inProgress else { return }
        // A download that ends before its engine named it is named first.
        named()
        var end = end
        if let placement {
            if end == .finished {
                do {
                    try BrowserDownloadPolicy.prepareForLanding(
                        placement.temporaryURL, source: sourceURL, quarantine: quarantine
                    )
                    let landed = try placement.finish()
                    destination = landed
                    filename = landed.lastPathComponent
                } catch {
                    placement.discard()
                    end = .failed(error.localizedDescription)
                }
            } else {
                placement.discard()
            }
        }
        if end == .finished {
            fraction = 1
        }
        status = end
        let handlers = finishHandlers
        finishHandlers = []
        handlers.forEach { $0(self) }
    }
}
