import Foundation

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)
    case remoteCommandFailed(String)
    case previewCapacity
    case remoteFileTooLarge

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed:
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed")
        case .previewCapacity:
            return String(localized: "fileExplorer.preview.capacity", defaultValue: "Close a Cloud file preview and try again.")
        case .remoteFileTooLarge:
            return String(localized: "fileExplorer.error.cloudPreviewTooLarge", defaultValue: "Cloud file previews are limited to 1 MB.")
        case .remoteCommandFailed:
            return String(localized: "fileExplorer.error.remoteFailed", defaultValue: "Remote command failed")
        }
    }
}
