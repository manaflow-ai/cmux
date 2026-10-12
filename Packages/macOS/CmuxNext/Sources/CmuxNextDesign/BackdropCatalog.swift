public import Foundation

/// The wallpaper choices displayed by Appearance settings.
public nonisolated struct BackdropCatalog: Sendable {
    /// The bundled art by collection (Dark Art, Museum Icons, Calm, Doré), then the person's own
    /// images, then the desktop picture, then a bounded starter set of macOS wallpapers.
    public let choices: [BackdropSelection]

    /// The bundled art in picker order: by collection, darkest works first within each.
    public static let bundled: [BackdropSelection] = BackdropArtCollection.allCases.flatMap { collection in
        BackdropArt.allCases.filter { $0.collection == collection }.map(BackdropSelection.art)
    }

    /// Builds a catalog from an injected directory listing.
    ///
    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper directory.
    ///   - fileManager: The file manager used to enumerate it.
    ///   - systemLimit: Maximum number of system wallpapers shown initially.
    ///   - userImages: The person's own images (``BackdropUserImages``), if any.
    public init(systemDirectory: URL, fileManager: FileManager, systemLimit: Int = 12, userImages: BackdropUserImages? = nil) {
        let extensions = Set(["jpg", "jpeg", "png", "heic", "heif", "avif"])
        let system = (try? fileManager.contentsOfDirectory(
            at: systemDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(max(0, systemLimit))
            .map { BackdropSelection.system(path: $0.path) } ?? []
        choices = Self.bundled + (userImages?.list(fileManager: fileManager) ?? []) + [.desktop] + system
    }
}
