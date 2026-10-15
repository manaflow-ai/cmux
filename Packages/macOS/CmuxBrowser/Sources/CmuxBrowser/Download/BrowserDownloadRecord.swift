public import Foundation

/// Immutable snapshot of a single browser download, surfaced in the
/// Safari/Chrome-style downloads popover. Value type so it can be passed below
/// the popover's `ForEach` boundary without dragging the `BrowserPanel` store
/// along (see the snapshot-boundary rule in CLAUDE.md).
public struct BrowserDownloadRecord: Identifiable, Equatable {
    public enum State: Equatable {
        case downloading
        case saved
        case failed
    }

    /// Stable id — the download's `download_id` from the event stream.
    public let id: String
    public var filename: String
    /// Final on-disk location once `state == .saved`.
    public var fileURL: URL?
    public var state: State
    /// File size in bytes once known (saved downloads only).
    public var byteCount: Int?
    /// Pause/resume and cancel for a running download, when its engine
    /// supports them (Chromium); `nil` for WebKit downloads, whose rows show
    /// no controls.
    public var controls: Controls?

    /// Controls of a running download.
    public struct Controls: Equatable, Sendable {
        /// Whether the download is paused.
        public var isPaused: Bool

        public init(isPaused: Bool = false) {
            self.isPaused = isPaused
        }
    }

    public init(
        id: String,
        filename: String,
        fileURL: URL? = nil,
        state: State,
        byteCount: Int? = nil,
        controls: Controls? = nil
    ) {
        self.id = id
        self.filename = filename
        self.fileURL = fileURL
        self.state = state
        self.byteCount = byteCount
        self.controls = controls
    }

    /// The controls a row shows: only while downloading, only when supported.
    public var visibleControls: Controls? {
        state == .downloading ? controls : nil
    }

    public var isComplete: Bool { state != .downloading }
}
