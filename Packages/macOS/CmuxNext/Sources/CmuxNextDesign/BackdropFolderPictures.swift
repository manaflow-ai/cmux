public import Foundation
import CmuxNextCompat

/// The pictures a folder shuffle (`appearance.background: "folder:<absolute path>"`) turns through:
/// every picture in the folder and its subfolders, so a wallpaper folder sorted into nested folders
/// shuffles all of them (Leo, 2026-11-16: "but i have a broader folder that has more stuff?").
///
/// The walk skips hidden files and folders, packages (an `.app` or `.photoslibrary` is not a folder
/// of wallpapers) and symbolic links, so it cannot loop; it stops ``maxDepth`` folders down and after
/// ``maxPictures`` pictures or ``maxEntries`` entries, so a huge folder cannot stall the app. Pictures
/// are ordered by their path relative to the folder, so one keeps its turn when others are added.
public nonisolated struct BackdropFolderPictures: Sendable {
    /// How many folders below the chosen one the walk reads (the folder itself is depth 0).
    public static let maxDepth = 8
    /// The most pictures one folder shuffle turns through.
    public static let maxPictures = 5_000
    /// The most files and folders the walk looks at, pictures or not.
    public static let maxEntries = 20_000

    /// The chosen folder, resolved (links followed, `/private` dropped as Foundation does), so every
    /// path this type names is spelled one way.
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The folder's pictures, recursively, ordered by relative path; downloaded art
    /// (`<art id>.avif`) is left out, as in ``BackdropUserImages/list(fileManager:)``. It reads the
    /// disk; the background clock calls it at a turn, at most every 15 minutes.
    public func list(maxDepth: Int = Self.maxDepth, maxPictures: Int = Self.maxPictures,
                     maxEntries: Int = Self.maxEntries) -> [BackdropSelection] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var found: [(relative: String, path: String)] = []
        var seen = 0
        // Depth first, children by name, so where a bound cuts the walk is the same every time.
        var stack: [(url: URL, relative: String, depth: Int)] = [(folder, "", 0)]
        walk: while let (directory, relative, depth) = stack.popLast() {
            let entries = (try? FileManager.checked.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            var subfolders: [(url: URL, relative: String, depth: Int)] = []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                seen += 1
                if seen > maxEntries { break walk }
                // Named from `directory`: a listing says /private/var where the resolved folder says /var.
                let name = entry.lastPathComponent
                let url = directory.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                // The listing fetched these keys, so this reads no more of the disk.
                guard let values = try? entry.blockingResourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if values.isPackage != true, depth < maxDepth { subfolders.append((url, path, depth + 1)) }
                } else if values.isRegularFile == true, BackdropUserImages.isImage(url), !BackdropUserImages.isDownloadedArt(url) {
                    found.append((path, url.path))
                    if found.count >= maxPictures { break walk }
                }
            }
            stack.append(contentsOf: subfolders.reversed())
        }
        return found.sorted { $0.relative < $1.relative }.map { BackdropSelection.file(path: $0.path) }
    }
}
