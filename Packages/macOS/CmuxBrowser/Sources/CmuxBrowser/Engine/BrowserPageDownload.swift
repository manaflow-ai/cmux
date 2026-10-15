public import Foundation

/// A download a page started, as reported by its engine.
public struct BrowserPageDownload: Equatable, Hashable, Sendable {
    /// The download's progress.
    public enum State: Equatable, Hashable, Sendable {
        /// Waiting for a destination.
        case pending
        /// Receiving bytes.
        case inProgress
        /// Finished and saved at ``BrowserPageDownload/destination``.
        case completed
        /// Cancelled by the user or the app.
        case cancelled
        /// Failed with the given message.
        case failed(String)
    }

    /// A stable identifier for the download within its page.
    public var id: String
    /// The URL being downloaded.
    public var url: URL?
    /// The file name the server or page suggested.
    public var suggestedFilename: String?
    /// Where the file is saved, once chosen.
    public var destination: URL?
    /// Bytes received so far.
    public var receivedBytes: Int64
    /// Expected total bytes, or `nil` when unknown.
    public var expectedBytes: Int64?
    /// The download's progress.
    public var state: State
    /// `true` while an in-progress download is paused (it can resume).
    public var isPaused: Bool

    /// Creates a download description.
    /// - Parameters:
    ///   - id: A stable identifier within the page.
    ///   - url: The URL being downloaded.
    ///   - suggestedFilename: The suggested file name.
    ///   - destination: The chosen destination, if any.
    ///   - receivedBytes: Bytes received so far.
    ///   - expectedBytes: Expected total bytes, if known.
    ///   - state: The download's progress.
    ///   - isPaused: Whether an in-progress download is paused; defaults to `false`.
    public init(
        id: String,
        url: URL?,
        suggestedFilename: String? = nil,
        destination: URL? = nil,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        state: State = .pending,
        isPaused: Bool = false
    ) {
        self.id = id
        self.url = url
        self.suggestedFilename = suggestedFilename
        self.destination = destination
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.state = state
        self.isPaused = isPaused
    }
}
