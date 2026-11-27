import Foundation
import CmuxCore

// User-facing strings stay in the app target so they resolve against the app
// bundle's localization tables (the package never localizes).
extension RemoteDropUploadError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "error.remoteDrop.unavailable",
                defaultValue: "Remote drop is unavailable."
            )
        case .invalidFileURL:
            String(
                localized: "error.remoteDrop.invalidFileURL",
                defaultValue: "Dropped item is not a file URL."
            )
        case .uploadFailed(let detail):
            String.localizedStringWithFormat(
                String(
                    localized: "error.remoteDrop.uploadFailed",
                    defaultValue: "Failed to upload dropped file: %@"
                ),
                detail
            )
        }
    }
}
