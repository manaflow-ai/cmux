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

    /// Where the file is written and lands (`BrowserDownloadPlacement`).
    @ObservationIgnored
    var placement: BrowserDownloadPlacement?
    @ObservationIgnored
    var cancelHandler: (() -> Void)?
    /// Pause and resume, when the engine can (Chromium).
    @ObservationIgnored
    var pauseHandler: ((Bool) -> Void)?
    @ObservationIgnored
    private var finishHandlers: [(BrowserDownload) -> Void] = []

    public init(sourceURL: URL?, filename: String) {
        self.sourceURL = sourceURL
        self.filename = filename
    }

    public var canPause: Bool { pauseHandler != nil && status == .inProgress }

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
    /// finished file moves from its temporary name into place
    /// (`BrowserDownloadPlacement.finish`; a failed move fails the
    /// download), the completion steps of `BrowserDownloadPolicy`
    /// (quarantine) run on the file where it landed, a failed or cancelled
    /// download leaves no file, and only the first end counts.
    func complete(_ end: Status) {
        guard status == .inProgress, end != .inProgress else { return }
        var end = end
        if let placement {
            if end == .finished {
                do {
                    let landed = try placement.finish()
                    destination = landed
                    filename = landed.lastPathComponent
                } catch {
                    end = .failed(error.localizedDescription)
                }
            } else {
                placement.discard()
            }
        }
        if end == .finished {
            fraction = 1
            BrowserDownloadPolicy.runCompletionSteps(for: self)
        }
        status = end
        let handlers = finishHandlers
        finishHandlers = []
        handlers.forEach { $0(self) }
    }
}
