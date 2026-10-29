import CmuxNextFileGrid
public import Foundation
import CmuxNextCompat

/// Finds the folders the Screenshots pane lists: macOS's screenshot folder,
/// macOS's floating-preview folder, every installed tool's save folder and
/// history (``ScreenshotTool``), and the person's own folders.
///
/// Pure over its ``ScreenshotEnvironment``: no folder is listed here, and a
/// folder shows only when it exists. Two sources never share a folder (the
/// first wins: CleanShot X saving into the macOS folder shows once, as the
/// macOS folder).
///
/// ```swift
/// let sources = ScreenshotSourceDetector(environment: SystemScreenshotEnvironment())
///     .detect(findTools: true, extraFolders: ["~/Pictures/Shots"])
/// ```
public nonisolated struct ScreenshotSourceDetector: Sendable {
    private let environment: any ScreenshotEnvironment

    /// The macOS screenshot preferences domain.
    public static let systemDomain = "com.apple.screencapture"
    /// The prefix of the folders macOS writes a screenshot into while its preview shows.
    public static let previewFolderPrefix = "NSIRD_screencaptureui_"

    /// Makes a detector.
    ///
    /// - Parameter environment: what it reads (the real Mac, or a test fixture).
    public init(environment: any ScreenshotEnvironment) {
        self.environment = environment
    }

    /// Every source, in menu order: macOS folder, macOS previews, tools (in ``ScreenshotTool``
    /// order, save folder then history), then the person's folders.
    ///
    /// - Parameters:
    ///   - findTools: look for third-party tools (`screenshots.findTools`); off lists only the macOS
    ///     folders and `extraFolders`.
    ///   - extraFolders: the person's folders (`screenshots.folders`): absolute or `~/` paths.
    /// - Returns: the sources whose folders exist, without duplicate folders.
    public func detect(findTools: Bool, extraFolders: [String]) -> [ScreenshotSource] {
        var sources: [ScreenshotSource] = []
        var seen: Set<String> = []
        func add(_ source: ScreenshotSource) {
            guard environment.isDirectory(source.folder) else { return }
            // FSEvents reports real paths (/private/var/..., not /var/...): the folder is kept that way
            // so a reported path matches its source.
            var source = source
            source.folder = Self.realFolder(source.folder)
            guard seen.insert(source.folder.path).inserted else { return }
            sources.append(source)
        }
        add(ScreenshotSource(id: "system", label: ScreenshotsStrings.systemSource, folder: systemFolder(), origin: .system,
                             rule: ScreenshotScanRule()))
        add(ScreenshotSource(id: "system.preview", label: ScreenshotsStrings.previewSource,
                             folder: environment.temporaryDirectory.appendingPathComponent("TemporaryItems", isDirectory: true),
                             origin: .systemPreview, rule: ScreenshotScanRule(depth: 1, folderPrefix: Self.previewFolderPrefix)))
        if findTools {
            for tool in ScreenshotTool.allCases {
                if let folder = saveFolder(of: tool) {
                    add(ScreenshotSource(id: "tool.\(tool.rawValue)", label: tool.displayName, folder: folder, origin: .tool(tool), rule: tool.rule))
                }
                for fixed in tool.fixedFolders {
                    let folder = environment.homeDirectory.appendingPathComponent(fixed.path, isDirectory: true)
                    let id = fixed.history ? "tool.\(tool.rawValue).history" : "tool.\(tool.rawValue)"
                    let label = fixed.history ? ScreenshotsStrings.history(of: tool.displayName) : tool.displayName
                    add(ScreenshotSource(id: id, label: label, folder: folder, origin: fixed.history ? .toolHistory(tool) : .tool(tool), rule: fixed.rule))
                }
            }
        }
        for path in extraFolders {
            guard let folder = expand(path) else { continue }
            add(ScreenshotSource(id: "custom.\(folder.path)", label: FileManager().displayName(atPath: folder.path), folder: folder,
                                 origin: .custom, rule: ScreenshotScanRule()))
        }
        return sources
    }

    /// macOS's screenshot folder: the `location` preference, else the Desktop.
    public func systemFolder() -> URL {
        if let location = environment.preference("location", domain: Self.systemDomain), let folder = expand(location),
           environment.isDirectory(folder) {
            return folder
        }
        return environment.homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// A tool's configured save folder: its exact key, a settings file, else any string preference
    /// whose key names a folder and whose value is an existing folder.
    func saveFolder(of tool: ScreenshotTool) -> URL? {
        for domain in tool.preferenceDomains {
            for key in tool.folderKeys {
                if let value = environment.preference(key, domain: domain), let folder = expand(value), environment.isDirectory(folder) {
                    return folder
                }
            }
        }
        if let file = tool.settingsFile,
           let text = environment.text(at: environment.homeDirectory.appendingPathComponent(file.path)),
           let value = file.format.value(of: file.key, in: text), let folder = expand(value), environment.isDirectory(folder) {
            return folder
        }
        for domain in tool.preferenceDomains {
            let values = environment.stringPreferences(domain: domain)
            for key in values.keys.sorted() where Self.looksLikeFolderKey(key) {
                if let value = values[key], let folder = expand(value), environment.isDirectory(folder) { return folder }
            }
        }
        return nil
    }

    /// Whether a preference key names a save folder (`exportPath`, `saveFolder`, `SaveLocation`, ...).
    ///
    /// - Parameter key: the preference key.
    public static func looksLikeFolderKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        guard !lowered.hasPrefix("ns"), !lowered.contains("recent") else { return false }
        return ["path", "folder", "location", "directory", "savedir", "exportdir"].contains { lowered.contains($0) }
    }

    /// The folder with every symlink resolved, as the kernel names it (`realpath`); the folder
    /// itself when it cannot be resolved.
    ///
    /// - Parameter folder: a folder URL.
    public static func realFolder(_ folder: URL) -> URL {
        let resolved = folder.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let real = blockingRealpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        }
        return resolved.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? folder.standardizedFileURL
    }

    /// An absolute path, a `~/` path or a `file://` URL as a folder URL; nil for anything else.
    func expand(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { return url.standardizedFileURL }
        if text == "~" { return environment.homeDirectory }
        if text.hasPrefix("~/") { return environment.homeDirectory.appendingPathComponent(String(text.dropFirst(2)), isDirectory: true) }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL }
        return nil
    }
}
