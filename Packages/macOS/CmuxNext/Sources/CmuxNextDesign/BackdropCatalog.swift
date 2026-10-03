import Foundation

/// The wallpaper choices displayed by Appearance settings.
public struct BackdropCatalog: Sendable {
    /// The bundled paintings followed by a bounded starter set of macOS wallpapers.
    public let choices: [BackdropSelection]

    /// Builds a catalog from an injected directory listing.
    ///
    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper directory.
    ///   - fileManager: The file manager used to enumerate it.
    ///   - systemLimit: Maximum number of system wallpapers shown initially.
    public init(systemDirectory: URL, fileManager: FileManager, systemLimit: Int = 12) {
        let extensions = Set(["jpg", "jpeg", "png", "heic", "heif", "avif"])
        let system = (try? fileManager.contentsOfDirectory(
            at: systemDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(max(0, systemLimit))
            .map { BackdropSelection.system(path: $0.path) } ?? []
        choices = BackdropArt.allCases.map(BackdropSelection.art) + system
    }
}
