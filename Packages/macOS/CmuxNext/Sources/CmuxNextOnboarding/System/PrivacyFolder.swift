import Foundation

/// The folders macOS guards with a privacy prompt the first time an app opens them.
public nonisolated enum PrivacyFolder: String, CaseIterable, Sendable {
    case desktop, documents, downloads, iCloudDrive

    var relativePath: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .iCloudDrive: "Library/Mobile Documents"
        }
    }
}
