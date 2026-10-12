import Foundation

/// The places macOS guards with a prompt the first time an app reads inside
/// them (LAUNCH-NO-TCC-PROMPTS): the user's Desktop, Documents, Downloads,
/// Pictures (the Photos library), Music (the Music library) and Movies,
/// iCloud Drive, cloud storage providers (`~/Library/CloudStorage`), other
/// apps' data (containers, Mail, Messages, Safari, Calendars), other volumes
/// and network volumes. Measured on macOS 27: listing or opening inside one
/// raises the prompt; a `stat` of a path does not. Scans still never look.
public nonisolated enum PrivacyFolder: String, CaseIterable, Sendable {
    case desktop, documents, downloads, pictures, music, movies, iCloudDrive, cloudStorage, appData, volumes, network

    /// The folders of this kind for the user whose home is `home`, from the one
    /// protected-folder list (cmux-tui/crates/acpmux/data/protected-folders.json).
    func roots(home: URL) -> [String] {
        ProtectedFolderEntry.inHome.filter { $0.kind == rawValue }.map { home.appending(path: $0.path).path }
            + ProtectedFolderEntry.roots.filter { $0.kind == rawValue }.map(\.path)
    }

    /// The kind `path` (absolute, standardized) sits in, if any. The Mac's
    /// disk ignores case, so `~/desktop/x` is on the Desktop too.
    static func of(path: String, home: URL) -> PrivacyFolder? {
        let path = path.lowercased()
        return allCases.first { kind in
            kind.roots(home: home).contains { root in
                let root = root.lowercased()
                return path == root || path.hasPrefix(root + "/")
            }
        }
    }
}
