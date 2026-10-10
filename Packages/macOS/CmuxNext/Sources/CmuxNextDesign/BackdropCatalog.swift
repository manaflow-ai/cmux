public import Foundation

/// The wallpaper choices displayed by Appearance settings.
public nonisolated struct BackdropCatalog: Sendable {
    /// The bundled figure drawings, then the bundled paintings, then the desktop picture, then a
    /// bounded starter set of macOS wallpapers.
    public let choices: [BackdropSelection]

    /// The bundled art in picker order (figure drawings first; the default is one).
    public static let bundled: [BackdropSelection] = [BackdropArtCollection.figureDrawings, .paintings].flatMap { collection in
        BackdropArt.allCases.filter { $0.collection == collection }.map(BackdropSelection.art)
    }

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
        choices = Self.bundled + [.desktop] + system
    }
}
