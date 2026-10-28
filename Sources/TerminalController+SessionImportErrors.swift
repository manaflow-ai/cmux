import Foundation
import CmuxWorkspaces

extension TerminalController {
    static func sessionImportErrorCode(_ error: SessionSnapshotImportError) -> String {
        switch error {
        case .fileNotFound, .noWindows:
            return "not_found"
        case .unreadable:
            return "invalid_state"
        case .notASessionSnapshot, .resourceLimitExceeded, .liveSnapshot:
            return "invalid_params"
        case .newerSchemaVersion, .olderSchemaVersion:
            return "unsupported"
        }
    }

    static func sessionImportErrorMessage(_ error: SessionSnapshotImportError) -> String {
        let path = error.fileURL.path
        switch error {
        case .fileNotFound:
            return String(
                format: String(
                    localized: "session.import.error.fileNotFound",
                    defaultValue: "No saved cmux session at %@."
                ),
                path
            )
        case .unreadable:
            return String(
                format: String(localized: "session.import.error.unreadable", defaultValue: "Could not read %@."),
                path
            )
        case .notASessionSnapshot:
            return String(
                format: String(
                    localized: "session.import.error.notASnapshot",
                    defaultValue: "%@ is not a cmux session snapshot."
                ),
                path
            )
        case .resourceLimitExceeded:
            return String(
                localized: "session.import.error.resourceLimit",
                defaultValue: "Could not open the selected session file. Choose a smaller or different file."
            )
        case let .newerSchemaVersion(_, found, supported):
            return String(
                format: String(
                    localized: "session.import.error.newerSchema",
                    defaultValue: "%1$@ was saved by a newer cmux (session format %2$@, this cmux reads %3$@). Update cmux to import it."
                ),
                path,
                String(found),
                String(supported)
            )
        case let .olderSchemaVersion(_, found, supported):
            return String(
                format: String(
                    localized: "session.import.error.olderSchema",
                    defaultValue: "%1$@ uses an older session format (%2$@) that this cmux no longer reads (%3$@)."
                ),
                path,
                String(found),
                String(supported)
            )
        case .noWindows:
            return String(
                format: String(
                    localized: "session.import.error.noWindows",
                    defaultValue: "%@ has no windows to restore."
                ),
                path
            )
        case .liveSnapshot:
            return String(
                format: String(
                    localized: "session.import.error.liveSnapshot",
                    defaultValue: "%@ is the session this cmux is saving right now. Run cmux restore-session without --from to reopen the previous launch."
                ),
                path
            )
        }
    }

}
