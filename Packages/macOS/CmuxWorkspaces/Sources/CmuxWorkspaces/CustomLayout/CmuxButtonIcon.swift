public import Bonsplit
import CmuxFoundation
import Foundation

/// The icon for a cmux config tab-bar / action button, in the `cmux.json`
/// wire schema.
///
/// Three forms map to the three Bonsplit button-icon kinds: an SF Symbol
/// (`{"type":"symbol","name":...}`), an emoji with an optional scale
/// (`{"type":"emoji","value":...,"scale":...}`), and a project-relative or
/// absolute image file (`{"type":"image","path":...}`). The hand-rolled
/// ``Codable`` conformance preserves the exact accepted aliases (`sfSymbol` /
/// `systemImage` for symbols, `file` for images) and validation (non-blank
/// trimmed strings, positive finite emoji scale, omitting `scale` on encode
/// when it equals `1`). Resolution into a renderable Bonsplit icon and into a
/// project-local change fingerprint goes through ``CmuxConfigImageAsset``.
public enum CmuxButtonIcon: Codable, Sendable, Hashable {
    /// An SF Symbol referenced by name.
    case symbol(String)
    /// An emoji glyph with a rendering scale (default `1`).
    case emoji(String, scale: Double = 1)
    /// A project-relative or absolute path to an image file.
    case imagePath(String)

    /// The SF Symbol name for a ``symbol`` icon, or `questionmark.circle` as a
    /// fallback for the non-symbol cases.
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

    /// Decodes an icon from its `cmux.json` object, accepting the `symbol` /
    /// `sfSymbol` / `systemImage` aliases, `emoji`, and `image` / `file`, and
    /// validating the referenced string fields and emoji scale.
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

    /// Encodes the icon back to its canonical `cmux.json` object, using the
    /// canonical `type` strings (`symbol`, `emoji`, `image`) and omitting the
    /// emoji `scale` when it equals `1`.
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

    /// Resolves this icon into a renderable Bonsplit button icon. For an image
    /// path it validates and loads the bytes via ``CmuxConfigImageAsset``
    /// (anchored at `configSourcePath`, gated against `globalConfigPath`),
    /// falling back to `questionmark.circle` when the path is disallowed and to
    /// `lock.fill` when a project-local image is not allowed by
    /// `allowProjectLocalImage`.
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
            guard let preparedImage = CmuxConfigImageAsset(
                path: path,
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

    /// The content fingerprint of this icon's project-local image, or `nil`
    /// when the icon is not a project-local image (so the app can detect
    /// changes to project-local image assets across reloads).
    public func projectLocalImageFingerprint(configSourcePath: String?, globalConfigPath: String) -> String? {
        guard case .imagePath(let path) = self,
              let preparedImage = CmuxConfigImageAsset(
                  path: path,
                  relativeToConfig: configSourcePath,
                  globalConfigPath: globalConfigPath
              ),
              preparedImage.isProjectLocal else {
            return nil
        }
        return preparedImage.fingerprint
    }

    /// Returns an icon whose image path is anchored to the directory containing
    /// `configSourcePath` (leaving non-image icons unchanged), so a stored icon
    /// carries an absolute path independent of the config's later location.
    public func resolvingRelativeImagePath(relativeToConfig configSourcePath: String?) -> CmuxButtonIcon {
        guard case .imagePath(let path) = self else { return self }
        let imagePath = configSourcePath.map(CmuxConfigImagePath.init(configSourcePath:))
        return .imagePath(imagePath.resolve(path))
    }

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
