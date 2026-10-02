import Foundation

/// The places macOS guards with a prompt the first time an app looks
/// inside them: the user's Desktop, Documents and Downloads, iCloud Drive,
/// cloud storage providers (`~/Library/CloudStorage`) and other volumes.
public nonisolated enum PrivacyFolder: String, CaseIterable, Sendable {
    case desktop, documents, downloads, iCloudDrive, cloudStorage, volumes

    /// The folder's path for the user whose home is `home`.
    func root(home: URL) -> String {
        switch self {
        case .desktop: home.appending(path: "Desktop").path
        case .documents: home.appending(path: "Documents").path
        case .downloads: home.appending(path: "Downloads").path
        case .iCloudDrive: home.appending(path: "Library/Mobile Documents").path
        case .cloudStorage: home.appending(path: "Library/CloudStorage").path
        case .volumes: "/Volumes"
        }
    }
}
