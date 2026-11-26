import CCmuxScreenshotsFFI
public import Foundation

/// Finds the folders the Screenshots pane lists: macOS's screenshot folder,
/// macOS's floating-preview folder, every installed tool's save folder and
/// history (``ScreenshotTool``), and the person's own folders. The finding is
/// Rust's (cmux-screenshots `detect.rs`, `tools.rs`); this answers its questions
/// from the ``ScreenshotEnvironment`` and names the sources.
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
        let json = ask { env, home in
            ScreenshotsFFI.bytes(environment.temporaryDirectory.path) { temporary, temporaryCount in
                ScreenshotsFFI.bytes(ScreenshotsFFI.json(extraFolders)) { extra, extraCount in
                    cmux_screenshots_detect(env, home.0, home.1, temporary, temporaryCount, findTools, extra, extraCount)
                }
            }
        }
        let found = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] } ?? []
        return found.compactMap(Self.source)
    }

    /// macOS's screenshot folder: the `location` preference, else the Desktop.
    public func systemFolder() -> URL {
        let path = ask { env, home in cmux_screenshots_system_folder(env, home.0, home.1) }
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? environment.homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Whether a preference key names a save folder (`exportPath`, `saveFolder`, `SaveLocation`, ...).
    ///
    /// - Parameter key: the preference key.
    public static func looksLikeFolderKey(_ key: String) -> Bool {
        ScreenshotsFFI.bytes(key) { cmux_screenshots_looks_like_folder_key($0, $1) }
    }

    /// A source from one entry of `cmux_screenshots_detect`'s JSON, with its menu label.
    private static func source(_ json: [String: Any]) -> ScreenshotSource? {
        guard let id = json["id"] as? String, let folderPath = json["folder"] as? String else { return nil }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let tool = (json["tool"] as? String).flatMap(ScreenshotTool.init(rawValue:))
        let toolName = json["toolName"] as? String ?? ""
        let origin: ScreenshotSourceOrigin
        let label: String
        switch (json["origin"] as? String, tool) {
        case ("system", _): (origin, label) = (.system, ScreenshotsStrings.systemSource)
        case ("systemPreview", _): (origin, label) = (.systemPreview, ScreenshotsStrings.previewSource)
        case ("tool", let tool?): (origin, label) = (.tool(tool), toolName)
        case ("toolHistory", let tool?): (origin, label) = (.toolHistory(tool), ScreenshotsStrings.history(of: toolName))
        case ("custom", _): (origin, label) = (.custom, FileManager().displayName(atPath: folder.path))
        default: return nil
        }
        return ScreenshotSource(id: id, label: label, folder: folder, origin: origin,
                                rule: ScreenshotScanRule(json: json["rule"] as? [String: Any] ?? [:]))
    }

    /// Runs `call` with this environment as the C ABI's callbacks and the home folder's bytes.
    private func ask(_ call: (UnsafePointer<CmuxScreenshotsEnvironment>, (UnsafePointer<UInt8>?, Int)) -> UnsafeMutablePointer<CChar>?) -> String? {
        let box = Unmanaged.passRetained(EnvironmentBox(environment))
        defer { box.release() }
        var env = CmuxScreenshotsEnvironment(
            context: box.toOpaque(),
            preference: { context, domain, domainCount, key, keyCount, reply in
                let environment = EnvironmentBox.environment(context)
                Detector.reply(reply, environment?.preference(Detector.string(key, keyCount), domain: Detector.string(domain, domainCount)))
            },
            string_preferences: { context, domain, domainCount, reply in
                let values = EnvironmentBox.environment(context)?.stringPreferences(domain: Detector.string(domain, domainCount))
                Detector.reply(reply, values.map { ScreenshotsFFI.json($0) })
            },
            text: { context, path, pathCount, reply in
                Detector.reply(reply, EnvironmentBox.environment(context)?.text(at: URL(fileURLWithPath: Detector.string(path, pathCount))))
            },
            is_directory: { context, path, pathCount in
                EnvironmentBox.environment(context)?.isDirectory(URL(fileURLWithPath: Detector.string(path, pathCount), isDirectory: true)) ?? false
            },
            real_path: { _, path, pathCount, reply in
                // FSEvents reports real paths (/private/var/..., not /var/...): a source's folder is kept that way.
                guard let real = realpath(Detector.string(path, pathCount), nil) else { return }
                defer { free(real) }
                Detector.reply(reply, String(cString: real))
            })
        return withUnsafePointer(to: &env) { env in
            ScreenshotsFFI.bytes(environment.homeDirectory.path) { ScreenshotsFFI.take(call(env, ($0, $1))) }
        }
    }

    private typealias Detector = ScreenshotSourceDetector

    private static func string(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> String {
        guard let bytes else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static func reply(_ reply: OpaquePointer?, _ value: String?) {
        guard let value else { return }
        ScreenshotsFFI.bytes(value) { cmux_screenshots_reply_set(reply, $0, $1) }
    }

    /// Carries the environment through the C ABI's context pointer for one call.
    private final class EnvironmentBox {
        let environment: any ScreenshotEnvironment
        init(_ environment: any ScreenshotEnvironment) { self.environment = environment }

        /// The environment behind a context pointer (the box `ask` retains for the call).
        static func environment(_ context: UnsafeMutableRawPointer?) -> (any ScreenshotEnvironment)? {
            context.map { Unmanaged<EnvironmentBox>.fromOpaque($0).takeUnretainedValue().environment }
        }
    }
}
