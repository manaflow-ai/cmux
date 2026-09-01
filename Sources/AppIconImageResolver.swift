import AppKit
import CmuxFoundation
import Foundation
import OSLog

nonisolated private let appIconImageResolverLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AppIcon"
)

/// Resolves a validated image path for the running app or its Dock tile.
struct AppIconImageResolver {
    static var defaultConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }

    static func image(
        for path: String,
        relativeToConfig configPath: String? = defaultConfigPath,
        log: (String) -> Void = { message in
            appIconImageResolverLogger.warning("\(message, privacy: .public)")
        }
    ) -> NSImage? {
        let result = CmuxValidatedImageAsset.prepare(
            path,
            relativeToConfig: configPath,
            globalConfigPath: defaultConfigPath
        )
        guard case .success(let prepared) = result else {
            if case .failure(let failure) = result {
                log("[AppIcon] rejected custom image: \(failure.description)")
            }
            return nil
        }
        guard let image = NSImage(data: prepared.data), image.isValid else {
            log("[AppIcon] custom image is not a supported image")
            return nil
        }
        return image
    }
}
