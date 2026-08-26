import AppKit
import Foundation

/// Resolves a validated image path for the running app or its Dock tile.
struct AppIconImageResolver {
    static var defaultConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }

    static func image(
        for path: String,
        relativeToConfig configPath: String? = defaultConfigPath
    ) -> NSImage? {
        let result = CmuxValidatedImageAsset.prepare(
            path,
            relativeToConfig: configPath,
            globalConfigPath: defaultConfigPath
        )
        guard case .success(let prepared) = result else {
            if case .failure(let failure) = result {
                NSLog("[AppIcon] rejected custom image path (%@): %@", path, failure.description)
            }
            return nil
        }
        guard let image = NSImage(data: prepared.data), image.isValid else {
            NSLog("[AppIcon] custom image is not a supported image: %@", prepared.resolvedPath)
            return nil
        }
        return image
    }
}
