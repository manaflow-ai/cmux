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
    /// An image decoded by the background resolver and transferred to the
    /// MainActor for the final AppKit assignment.
    struct PreparedImage: @unchecked Sendable {
        let image: NSImage

        init(image: NSImage) {
            self.image = image
        }
    }

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
        return image(from: prepared, log: log)
    }

    /// Prepares a custom image off the caller's actor, returning only the
    /// Sendable validated bytes needed for a later AppKit decode.
    @concurrent
    nonisolated
    static func preparedAsset(
        for path: String,
        relativeToConfig configPath: String? = defaultConfigPath,
        log: @escaping @Sendable (String) -> Void = { message in
            appIconImageResolverLogger.warning("\(message, privacy: .public)")
        }
    ) async -> CmuxValidatedImageAsset.Prepared? {
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
        return prepared
    }

    /// Validates and decodes a custom image without running file work on the
    /// caller's actor.
    @concurrent
    nonisolated
    static func isValid(
        for path: String,
        relativeToConfig configPath: String? = defaultConfigPath,
        log: @escaping @Sendable (String) -> Void = { message in
            appIconImageResolverLogger.warning("\(message, privacy: .public)")
        }
    ) async -> Bool {
        await preparedImage(
            for: path,
            relativeToConfig: configPath,
            log: log
        ) != nil
    }

    /// Validates and decodes a custom image off the caller's actor. The
    /// resulting AppKit object is immutable for this handoff and is only
    /// assigned to application state after returning to MainActor.
    @concurrent
    nonisolated
    static func preparedImage(
        for path: String,
        relativeToConfig configPath: String? = defaultConfigPath,
        log: @escaping @Sendable (String) -> Void = { message in
            appIconImageResolverLogger.warning("\(message, privacy: .public)")
        }
    ) async -> PreparedImage? {
        guard let prepared = await preparedAsset(
            for: path,
            relativeToConfig: configPath,
            log: log
        ), let image = image(from: prepared, log: log) else {
            return nil
        }
        return PreparedImage(image: image)
    }

    /// Decodes already-validated bytes on the caller's actor.
    nonisolated
    static func image(
        from prepared: CmuxValidatedImageAsset.Prepared,
        log: (String) -> Void = { message in
            appIconImageResolverLogger.warning("\(message, privacy: .public)")
        }
    ) -> NSImage? {
        guard let image = NSImage(data: prepared.data), image.isValid else {
            log("[AppIcon] custom image is not a supported image")
            return nil
        }
        return image
    }
}
