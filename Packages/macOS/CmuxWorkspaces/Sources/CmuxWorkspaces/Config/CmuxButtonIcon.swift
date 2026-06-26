public import Bonsplit
import CmuxFoundation
import CryptoKit
import Foundation

/// A config-declared icon for a cmux tab-bar/action button: an SF Symbol, an
/// emoji (with an optional render scale), or a path to a project-local or global
/// image asset. Decodes from the `{ "type": ... }` icon JSON in `cmux.json`,
/// validates and prepares image-asset bytes (size-capped, SVG-sanitized,
/// project-root-scoped), and maps to a `Bonsplit` split-action-button icon.
public enum CmuxButtonIcon: Codable, Sendable, Hashable {
    /// An SF Symbol referenced by its system symbol name.
    case symbol(String)
    /// An emoji glyph rendered at the given scale (1 = native size).
    case emoji(String, scale: Double = 1)
    /// A path (project-local or global) to an image asset on disk.
    case imagePath(String)

    /// The SF Symbol name for a `.symbol` icon, falling back to
    /// `"questionmark.circle"` for emoji/image icons.
    public var symbolName: String {
        if case .symbol(let name) = self {
            return name
        }
        return "questionmark.circle"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case value
        case path
        case scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try Self.trimmedString(forKey: .type, in: container)
        switch type {
        case "symbol", "sfSymbol", "systemImage":
            self = .symbol(try Self.trimmedString(forKey: .name, in: container))
        case "emoji":
            self = .emoji(
                try Self.trimmedString(forKey: .value, in: container),
                scale: try Self.emojiScale(in: container)
            )
        case "image", "file":
            self = .imagePath(try Self.trimmedString(forKey: .path, in: container))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown icon type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name):
            try container.encode("symbol", forKey: .type)
            try container.encode(name, forKey: .name)
        case .emoji(let value, let scale):
            try container.encode("emoji", forKey: .type)
            try container.encode(value, forKey: .value)
            if scale != 1 {
                try container.encode(scale, forKey: .scale)
            }
        case .imagePath(let path):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    /// Maps this icon to a `Bonsplit` split-action-button icon, preparing and
    /// validating image bytes for `.imagePath` icons. A disallowed image path
    /// falls back to `"questionmark.circle"`; a project-local image rejected by
    /// `allowProjectLocalImage` falls back to `"lock.fill"`.
    public func bonsplitIcon(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalImage: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton.Icon {
        switch self {
        case .symbol(let name):
            return .systemImage(name)
        case .emoji(let value, let scale):
            return .emoji(value, scale: scale)
        case .imagePath(let path):
            guard let preparedImage = Self.preparedImageAsset(
                path,
                relativeToConfig: configSourcePath,
                globalConfigPath: globalConfigPath
            ) else {
                NSLog("[CmuxConfig] icon image path is not allowed: %@", path)
                return .systemImage("questionmark.circle")
            }
            if preparedImage.isProjectLocal && !allowProjectLocalImage {
                return .systemImage("lock.fill")
            }
            return .imageData(preparedImage.data)
        }
    }

    /// The SHA-256 fingerprint of a project-local image icon's bytes, or `nil`
    /// for non-image, global, or unresolvable icons. Used to detect changes to a
    /// project-local asset.
    public func projectLocalImageFingerprint(configSourcePath: String?, globalConfigPath: String) -> String? {
        guard case .imagePath(let path) = self,
              let preparedImage = Self.preparedImageAsset(
                  path,
                  relativeToConfig: configSourcePath,
                  globalConfigPath: globalConfigPath
              ),
              preparedImage.isProjectLocal else {
            return nil
        }
        return preparedImage.fingerprint
    }

    /// Returns a copy with a `.imagePath` resolved against the config source
    /// directory (absolutizing a relative path); other cases are returned
    /// unchanged.
    public func resolvingRelativeImagePath(relativeToConfig configSourcePath: String?) -> CmuxButtonIcon {
        guard case .imagePath(let path) = self else { return self }
        return .imagePath(Self.resolvePath(path, relativeToConfig: configSourcePath))
    }

    private static let maxImageBytes = 1_000_000

    private static func emojiScale(in container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        let scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        guard scale.isFinite, scale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .scale,
                in: container,
                debugDescription: "Emoji icon scale must be a positive number"
            )
        }
        return scale
    }

    private struct PreparedImageAsset {
        let data: Data
        let fingerprint: String
        let isProjectLocal: Bool
    }

    private static func resolvePath(_ path: String, relativeToConfig configSourcePath: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        guard let configSourcePath else { return expanded }
        let base = (configSourcePath as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(expanded)
    }

    private static func safeResolvedImagePath(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("http://"),
              !trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }

        let isGlobal = configSourcePath == nil || configSourcePath == globalConfigPath
        if !isGlobal {
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !(expanded as NSString).isAbsolutePath,
                  expanded == trimmed else {
                return nil
            }
        }

        let resolvedPath = resolvePath(trimmed, relativeToConfig: configSourcePath)
        guard !resolvedPath.isEmpty else { return nil }
        let standardizedPath = (resolvedPath as NSString).standardizingPath

        guard !isGlobal, let configSourcePath else {
            return standardizedPath
        }

        let allowedRoot = projectRoot(forConfigPath: configSourcePath)
        let resolvedURL = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath()
        let allowedURL = URL(fileURLWithPath: allowedRoot).resolvingSymlinksInPath()
        let resolved = resolvedURL.path
        let allowed = allowedURL.path
        guard resolved == allowed || resolved.hasPrefix(allowed + "/") else {
            return nil
        }
        return resolved
    }

    private static func preparedImageAsset(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> PreparedImageAsset? {
        guard let resolvedPath = safeResolvedImagePath(
            path,
            relativeToConfig: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: resolvedPath) else {
            NSLog("[CmuxConfig] icon image does not exist: %@", resolvedPath)
            return nil
        }
        guard data.count <= maxImageBytes else {
            NSLog("[CmuxConfig] icon image is too large: %@", resolvedPath)
            return nil
        }
        let svgValidator = SVGMarkupValidator()
        if svgValidator.looksLikeSVGPath(resolvedPath), !svgValidator.isSafeSVG(data: data) {
            NSLog("[CmuxConfig] icon SVG contains unsupported content: %@", resolvedPath)
            return nil
        }

        let isProjectLocal = configSourcePath != nil && configSourcePath != globalConfigPath
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PreparedImageAsset(data: data, fingerprint: fingerprint, isProjectLocal: isProjectLocal)
    }

    /// The directory treated as the project root for a config at `configPath`:
    /// the config's parent directory, or its grandparent when the config lives in
    /// a `.cmux` directory. Image-asset paths are scoped to this root.
    public static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".cmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}
