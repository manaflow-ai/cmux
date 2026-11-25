import CmuxNextBrowser
import Foundation

/// The Downloads list's ended downloads (`BrowserDownloadHistory`, in CmuxNextBrowser), in this build's own folder.
extension BrowserDownloadHistory {
    /// `<Application Support>/<bundle id>/downloads.json`.
    static func forApplication(bundleIdentifier: String?) -> BrowserDownloadHistory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return BrowserDownloadHistory(storage: BrowserDownloadHistoryStorage(
            url: support.appending(path: bundle).appending(path: "downloads.json")
        ))
    }
}
