import CryptoKit
import Foundation

/// Shared, bounded validation for image files referenced by cmux settings.
///
/// The same path policy is used by configurable button icons and the custom
/// app icon. Global settings may reference any local file; project settings
/// remain confined to their project root. Remote URLs, oversized files, and
/// SVGs with executable or external content are rejected before image data is
/// handed to AppKit.
struct CmuxValidatedImageAsset {
    static let maxImageBytes = 1_000_000

    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyPath
        case remotePath
        case projectPathNotAllowed
        case missingFile
        case notRegularFile
        case unreadableFile
        case tooLarge
        case unsafeSVG

        var description: String {
            switch self {
            case .emptyPath: return "empty path"
            case .remotePath: return "remote URL"
            case .projectPathNotAllowed: return "path is outside the project root"
            case .missingFile: return "file does not exist"
            case .notRegularFile: return "path is not a regular file"
            case .unreadableFile: return "file cannot be read"
            case .tooLarge: return "file exceeds the 1 MB limit"
            case .unsafeSVG: return "SVG contains unsupported or external content"
            }
        }
    }

    struct Prepared: Equatable {
        let data: Data
        let resolvedPath: String
        let fingerprint: String
    }

    /// Resolves a user path without reading the file. Relative paths are
    /// resolved beside the settings file when one is supplied.
    static func normalizedPath(_ path: String, relativeToConfig configPath: String?) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0") else {
            return nil
        }
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("http://"),
              !lowered.hasPrefix("https://") else {
            return nil
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return (expanded as NSString).standardizingPath
        }
        guard let configPath else {
            return (expanded as NSString).standardizingPath
        }
        let base = (configPath as NSString).deletingLastPathComponent
        let resolved = (base as NSString).appendingPathComponent(expanded)
        return (resolved as NSString).standardizingPath
    }

    static func prepare(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String,
        readContents: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) -> Result<Prepared, Failure> {
        guard let resolvedPath = safeResolvedImagePath(
            path,
            relativeToConfig: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .failure(.emptyPath) }
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
                return .failure(.remotePath)
            }
            return .failure(.projectPathNotAllowed)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .failure(.missingFile)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return .failure(.notRegularFile)
        }
        if let fileSize = attributes[.size] as? NSNumber,
           fileSize.uint64Value > UInt64(maxImageBytes) {
            return .failure(.tooLarge)
        }
        guard let data = readContents(resolvedPath) else {
            return .failure(.unreadableFile)
        }
        guard data.count <= maxImageBytes else {
            return .failure(.tooLarge)
        }
        if (resolvedPath as NSString).pathExtension.lowercased() == "svg",
           !isSafeSVG(data: data) {
            return .failure(.unsafeSVG)
        }

        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return .success(
            Prepared(
                data: data,
                resolvedPath: resolvedPath,
                fingerprint: fingerprint
            )
        )
    }

    static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".cmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    private static func safeResolvedImagePath(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedPath = normalizedPath(trimmed, relativeToConfig: configSourcePath) else {
            return nil
        }

        let normalizedSource = normalizedPath(configSourcePath ?? "", relativeToConfig: nil)
        let normalizedGlobal = normalizedPath(globalConfigPath, relativeToConfig: nil)
        let isGlobal = configSourcePath == nil || normalizedSource == normalizedGlobal
        guard !isGlobal else { return resolvedPath }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !(expanded as NSString).isAbsolutePath,
              expanded == trimmed else {
            return nil
        }

        let allowedRoot = projectRoot(forConfigPath: configSourcePath!)
        let resolvedURL = URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath()
        let allowedURL = URL(fileURLWithPath: allowedRoot).resolvingSymlinksInPath()
        let resolved = resolvedURL.path
        let allowed = allowedURL.path
        guard resolved == allowed || resolved.hasPrefix(allowed + "/") else {
            return nil
        }
        return resolved
    }

    private static func isSafeSVG(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"),
              !lowered.contains("<!entity") else {
            return false
        }

        let inspector = CmuxSVGSecurityInspector()
        return inspector.parse(data: data)
    }
}
