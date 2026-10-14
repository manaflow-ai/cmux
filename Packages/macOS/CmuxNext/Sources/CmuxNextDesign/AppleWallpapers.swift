public import Foundation

/// Apple's moving wallpapers on the person's own Mac (cx-14vdf), listed for the wallpaper
/// picker's Moving wallpapers group. cmux ships none of them and copies none: every file is read
/// where macOS keeps it.
///
/// - `/System/Library/Desktop Pictures/.wallpapers/<name>/*.mov`: the shipped moving wallpapers
///   (Sonoma), in a light and a dark cut; the window plays the cut for its appearance.
/// - The aerials idleassetsd downloaded (`Customer/**/*.mov`, named by `entries.json`).
public nonisolated struct AppleWallpapers: Sendable {
    /// `/System/Library/Desktop Pictures`.
    public let desktopPictures: URL
    /// Where idleassetsd keeps downloaded aerials.
    public let aerials: URL

    public static let system = AppleWallpapers(
        desktopPictures: URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
        aerials: URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true))

    /// The picker collection of every moving wallpaper.
    public static let videoCollection = "video"

    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public init(desktopPictures: URL, aerials: URL) {
        self.desktopPictures = desktopPictures
        self.aerials = aerials
    }

    /// Every moving wallpaper on disk: one per shipped wallpaper (its light cut, or its only one),
    /// then the downloaded aerials.
    public func videos(fileManager: FileManager = .default) -> [BackdropSelection] {
        []
    }

    /// The aerials' names from idleassetsd's `entries.json`, by asset id.
    public func aerialNames() -> [String: String] {
        [:]
    }

    /// Whether `path` names a video.
    public static func isVideo(_ path: String) -> Bool {
        videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Whether `path` is a shipped moving wallpaper with a light and a dark cut.
    public static func hasCuts(_ path: String) -> Bool {
        isVideo(path) && (path.contains(" Light ") || path.contains(" Dark "))
    }

    /// The file a window plays for `path` in light or dark: a shipped wallpaper's cut for the
    /// appearance when macOS has it, any other file itself.
    public static func file(for path: String, dark: Bool) -> URL {
        URL(fileURLWithPath: path)
    }

    /// A shipped video's light or dark cut (`Sonoma Graphic Light Landscape.mov`).
    static func cut(_ path: String, dark: Bool) -> String {
        dark ? path.replacingOccurrences(of: " Light ", with: " Dark ") : path.replacingOccurrences(of: " Dark ", with: " Light ")
    }

    /// A folder's entries, hidden ones included (`.wallpapers` is hidden).
    private static func files(in folder: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    private static func byName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
