public import Foundation

/// The page state a browser pane keeps when its web view is dropped, so the
/// replacement can come back where the user left it.
public struct BrowserPageStateCapture: Equatable, Sendable {
    /// Upper bound for session state written to the session file. Typical
    /// pages serialize to a few kilobytes; very long histories are dropped
    /// rather than bloating every autosave.
    public static let defaultPersistableInteractionStateByteLimit = 256 * 1024

    /// WebKit `interactionState`: the back/forward list plus each entry's
    /// scroll and view state. Nil when no replayable page was showing.
    public var interactionState: Data?
    /// URL of the document WebKit had committed when the state was captured.
    /// This is the URL WebKit loads on restore, which can differ from the
    /// display URL (remote proxy loopback aliases).
    public var documentURL: URL?
    /// The restore URL the pane resolves right after the discard. Restore uses
    /// the captured state only while the pane still points at this URL.
    public var anchorURL: URL?
    /// Unsaved form input from the main frame, kept in memory only.
    public var formState: BrowserFormStateSnapshot?
    /// JPEG of the page painted while the restore loads.
    public var snapshot: BrowserPageSnapshotImage?
    /// Token of the snapshot request whose result belongs to this capture.
    public var snapshotToken: UUID?
    /// Whether the native back/forward list is the pane's history. False while
    /// the pane replays URL history restored from a previous launch, which the
    /// restore must then keep.
    public var coversNavigationHistory: Bool
    /// Whether any entry came from a form submission. WebKit serializes POST
    /// bodies into session state, so such state never reaches disk.
    public var containsFormSubmission: Bool
    /// Whether the current entry, or one of its frames, came from a form
    /// submission, so assigning the state would submit the form again.
    public var documentHasFormSubmission: Bool

    public init(
        interactionState: Data?,
        documentURL: URL?,
        anchorURL: URL? = nil,
        formState: BrowserFormStateSnapshot? = nil,
        snapshot: BrowserPageSnapshotImage? = nil,
        snapshotToken: UUID? = nil,
        coversNavigationHistory: Bool,
        containsFormSubmission: Bool,
        documentHasFormSubmission: Bool = false
    ) {
        self.interactionState = interactionState
        self.documentURL = documentURL
        self.anchorURL = anchorURL
        self.formState = formState
        self.snapshot = snapshot
        self.snapshotToken = snapshotToken
        self.coversNavigationHistory = coversNavigationHistory
        self.containsFormSubmission = containsFormSubmission
        self.documentHasFormSubmission = documentHasFormSubmission
    }

    /// Session state that may be written to the session file, or nil when it
    /// is missing, too large, replays restored URL history, or holds a form
    /// submission.
    public func persistableInteractionState(
        maxBytes: Int = defaultPersistableInteractionStateByteLimit
    ) -> Data? {
        Self.persistableInteractionState(
            interactionState,
            coversNavigationHistory: coversNavigationHistory,
            containsFormSubmission: containsFormSubmission || formState?.isEmpty == false,
            maxBytes: maxBytes
        )
    }

    /// Shared persistence gate for captured and live session state.
    public static func persistableInteractionState(
        _ interactionState: Data?,
        coversNavigationHistory: Bool,
        containsFormSubmission: Bool,
        maxBytes: Int = defaultPersistableInteractionStateByteLimit
    ) -> Data? {
        guard let interactionState,
              !interactionState.isEmpty,
              interactionState.count <= maxBytes,
              coversNavigationHistory,
              !containsFormSubmission else {
            return nil
        }
        return interactionState
    }
}

/// A compressed bitmap of a page and the size, in points, it was taken at.
public struct BrowserPageSnapshotImage: Equatable, Sendable {
    public var jpegData: Data
    public var pointSize: CGSize

    public init(jpegData: Data, pointSize: CGSize) {
        self.jpegData = jpegData
        self.pointSize = pointSize
    }
}
