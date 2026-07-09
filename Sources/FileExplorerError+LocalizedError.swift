import CmuxFoundation
import Foundation

// `FileExplorerError`'s case shape lives in CmuxFoundation so provider/transport
// code can throw it, but its user-facing `errorDescription` stays app-side: here
// `String(localized:)` resolves against the app bundle's string catalog, so the
// Japanese and Korean translations are preserved. Resolving the keys inside the
// package would bind to the package bundle (no catalog) and silently fall back to
// the English default for every non-English locale.
extension FileExplorerError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed:
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed")
        }
    }
}
