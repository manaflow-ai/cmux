import Darwin
import Foundation

/// A minimal `cmux Computer Use.app` tree inside a private temporary directory.
///
/// The tree mirrors the shipped helper's shape: directories, regular files,
/// and a hidden marker file, so a quarantine pass has to handle each kind.
struct HelperBundleFixture {
    /// The temporary directory that owns everything the fixture creates.
    let root: URL
    /// The helper bundle, `root/cmux Computer Use.app`.
    let bundle: URL
    /// The helper executable inside `bundle`.
    let executable: URL
    /// The `Info.plist` inside `bundle`.
    let infoPlist: URL
    /// The hidden managed-helper marker inside `bundle`.
    let hiddenMarker: URL

    private let fileManager: FileManager

    /// Creates the tree on disk.
    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        root = Self.canonicalTemporaryDirectory(fileManager).appendingPathComponent(
            "cmux-computer-use-helper-\(UUID().uuidString)",
            isDirectory: true
        )
        bundle = root.appendingPathComponent("cmux Computer Use.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOSDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        executable = macOSDirectory.appendingPathComponent("cmux-cua", isDirectory: false)
        infoPlist = contents.appendingPathComponent("Info.plist", isDirectory: false)
        hiddenMarker = resources.appendingPathComponent(
            ".cmux-cua-managed-helper",
            isDirectory: false
        )
        try fileManager.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("<plist/>".utf8).write(to: infoPlist)
        try Data("managed".utf8).write(to: hiddenMarker)
    }

    /// Every entry of a bundle tree, the bundle itself first.
    ///
    /// Symbolic links are listed as themselves and never followed.
    func entries(of bundleURL: URL) throws -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: bundleURL,
                includingPropertiesForKeys: [],
                options: []
            )
        else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries = [bundleURL]
        for case let entry as URL in enumerator {
            entries.append(entry)
        }
        return entries
    }

    /// Every entry of the fixture's own bundle, the bundle itself first.
    func bundleEntries() throws -> [URL] {
        try entries(of: bundle)
    }

    /// Deletes the temporary directory.
    func remove() {
        for entry in (try? entries(of: root)) ?? [] {
            var metadata = stat()
            if lstat(entry.path, &metadata) == 0,
               metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                _ = chmod(entry.path, 0o755)
            }
        }
        try? fileManager.removeItem(at: root)
    }

    /// Models the read-only directory permissions carried by a Nix bundle.
    func makeReadOnly(_ bundleURL: URL) throws {
        for entry in try entries(of: bundleURL) {
            var metadata = stat()
            if lstat(entry.path, &metadata) == 0,
               metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: entry.path)
            }
        }
    }

    /// The temporary directory with `/var` resolved to `/private/var`.
    ///
    /// `realpath(3)` keeps the `/private` prefix that Foundation's own URL
    /// resolution strips, so fixture URLs compare equal to the URLs
    /// `FileManager` enumeration produces.
    private static func canonicalTemporaryDirectory(_ fileManager: FileManager) -> URL {
        let path = fileManager.temporaryDirectory.path
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
