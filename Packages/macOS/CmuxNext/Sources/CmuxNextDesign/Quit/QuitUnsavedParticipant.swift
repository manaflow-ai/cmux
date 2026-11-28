import Foundation

/// A surface with unsaved state that the quit must save or discard (R96
/// quit hook). One participant per document: two tabs on one file share
/// `quitParticipantID`, `file:<host id>:<canonical path>` (host id "local"
/// for this Mac; build it with `QuitParticipantID.file(host:path:)`).
/// Register it with `QuitUnsavedRegistry.shared.register(_:)`, which refuses
/// any other id; write its recovery draft on every edit through
/// `RecoveryDraftStore.shared` with the same id.
@MainActor
public protocol QuitUnsavedParticipant: AnyObject {
    /// `file:<host id>:<canonical path>`; also the recovery draft's id.
    var quitParticipantID: String { get }
    /// Shown in the quit dialog, e.g. "notes.md (api)".
    var quitTitle: String { get }
    /// Correct at once: true from the first edit.
    var hasUnsavedChanges: Bool { get }
    /// How long a save may take; capped at `QuitUnsavedRegistry.maxDeadline`.
    var quitFlushDeadline: Duration { get }
    /// Saves now; throws `QuitFlushError` for a reason the dialog shows.
    func flushForQuit() async throws
    /// "Don't Save".
    func discardForQuit() async
}

public extension QuitUnsavedParticipant {
    var quitFlushDeadline: Duration { .seconds(3) }
}

/// Why a save failed, shown in the quit dialog.
public nonisolated enum QuitFlushError: Error, Equatable, Sendable {
    /// The file changed on disk; the String names it.
    case conflict(String)
    case readOnly(String)
    case failed(String)

    public var reason: String {
        switch self {
        case .conflict(let name): String(format: QuitFlushStrings.conflict, name)
        case .readOnly(let name): String(format: QuitFlushStrings.readOnly, name)
        case .failed(let message): message
        }
    }
}
