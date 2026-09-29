public import Foundation
public import Observation

/// A download in progress or completed.
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
    public internal(set) var status: Status = .inProgress

    @ObservationIgnored
    var cancelHandler: (() -> Void)?

    public init(sourceURL: URL?, filename: String) {
        self.sourceURL = sourceURL
        self.filename = filename
    }

    public func cancel() {
        guard status == .inProgress else { return }
        cancelHandler?()
        status = .cancelled
    }
}

// MARK: - Find and snapshots
