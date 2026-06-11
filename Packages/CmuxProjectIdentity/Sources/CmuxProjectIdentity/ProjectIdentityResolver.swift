import AppKit
public import Foundation

/// Resolves the visual identity of a project from its files on disk.
///
/// This is a Service: it performs filesystem reads and image decoding off the
/// main actor, and returns a `Sendable` ``ProjectIdentity``. Construct one at
/// the app composition root and inject it; do not use a shared instance.
///
/// ```swift
/// let resolver = ProjectIdentityResolver(fileManager: .default)
/// let identity = await resolver.resolve(projectRootPath: "/path/to/repo")
/// ```
public actor ProjectIdentityResolver {
    private let fileManager: FileManager
    private let locator: AppIconImageLocator
    private let averageColor = AverageColor()

    /// Creates a resolver. Inject a `FileManager` for testing.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.locator = AppIconImageLocator(fileManager: fileManager)
    }

    /// Resolves the identity for the project rooted at `projectRootPath`.
    ///
    /// Always returns a value: when no `AppIcon` asset is found, the icon and
    /// color are `nil` and only the name + ``ProjectMonogram`` are populated.
    public func resolve(projectRootPath: String) async -> ProjectIdentity {
        let locator = self.locator
        let averageColor = self.averageColor
        return await Task.detached(priority: .utility) {
            let root = URL(fileURLWithPath: projectRootPath, isDirectory: true)
            let name = root.lastPathComponent
            let monogram = ProjectMonogram(projectName: name).value

            guard let iconURL = locator.bestIconURL(inProjectRoot: root),
                  let imageData = try? Data(contentsOf: iconURL),
                  let image = NSImage(data: imageData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                return ProjectIdentity(projectName: name, iconImageData: nil, dominantColorHex: nil, monogram: monogram)
            }
            let colorHex = averageColor.hexString(of: cgImage)
            return ProjectIdentity(projectName: name, iconImageData: imageData, dominantColorHex: colorHex, monogram: monogram)
        }.value
    }
}
