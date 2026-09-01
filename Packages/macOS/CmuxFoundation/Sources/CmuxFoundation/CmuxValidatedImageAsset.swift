import CryptoKit
public import Foundation

/// Shared, bounded validation for image files referenced by cmux settings.
///
/// The same path policy is used by configurable button icons and the custom
/// app icon. Global settings may reference any local file; project settings
/// remain confined to their project root. Remote URLs, oversized files, and
/// SVGs with executable or external content are rejected before image data is
/// handed to AppKit.
public struct CmuxValidatedImageAsset {
    /// Maximum number of bytes accepted for one image payload.
    public static let maxImageBytes = 1_000_000

    /// Reasons a configured image cannot be prepared for AppKit.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The supplied path is empty after trimming whitespace.
        case emptyPath
        /// The supplied path uses an HTTP or HTTPS URL.
        case remotePath
        /// A project-local path escapes its permitted project root.
        case projectPathNotAllowed
        /// No file exists at the resolved path.
        case missingFile
        /// The resolved path is not a regular file.
        case notRegularFile
        /// The file exists but its contents could not be read.
        case unreadableFile
        /// The file exceeds ``maxImageBytes``.
        case tooLarge
        /// The SVG contains executable or externally loaded content.
        case unsafeSVG

        /// A concise, path-free diagnostic suitable for user-facing logs.
        public var description: String {
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

    /// Validated image bytes together with their canonical path and fingerprint.
    public struct Prepared: Equatable, Sendable {
        /// The bounded image payload.
        public let data: Data
        /// The normalized path that was validated.
        public let resolvedPath: String
        /// SHA-256 fingerprint of ``data``.
        public let fingerprint: String

        /// Creates a prepared image value from validated data.
        ///
        /// - Parameters:
        ///   - data: Bounded image bytes.
        ///   - resolvedPath: Canonical path associated with `data`.
        ///   - fingerprint: SHA-256 fingerprint of `data`.
        public init(data: Data, resolvedPath: String, fingerprint: String) {
            self.data = data
            self.resolvedPath = resolvedPath
            self.fingerprint = fingerprint
        }
    }

    /// Resolves a user path without reading the file.
    ///
    /// - Parameters:
    ///   - path: Absolute or config-relative local path.
    ///   - configPath: Config file used to resolve a relative path.
    /// - Returns: A standardized local path, or `nil` for an empty, NUL-filled,
    ///   or remote path.
    public static func normalizedPath(_ path: String, relativeToConfig configPath: String?) -> String? {
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

    /// Validates and reads one configured image path.
    ///
    /// - Parameters:
    ///   - path: Absolute or config-relative local path.
    ///   - configSourcePath: Config file used to resolve relative paths.
    ///   - globalConfigPath: Canonical global config path used to distinguish
    ///     project-local confinement from global settings.
    /// - Returns: Prepared image data, or a path-free validation failure.
    public static func prepare(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
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
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0,
              fileSize.int64Value <= Int64(maxImageBytes) else {
            return .failure(.tooLarge)
        }
        guard let data = boundedImageContents(atPath: resolvedPath) else {
            return .failure(.unreadableFile)
        }
        guard data.count <= maxImageBytes else {
            return .failure(.tooLarge)
        }
        let hasSVGExtension = (resolvedPath as NSString).pathExtension.lowercased() == "svg"
        if (hasSVGExtension || isSVGDocument(data: data)) && !isSafeSVG(data: data) {
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

    /// Returns the project root associated with a config path.
    ///
    /// - Parameter configPath: The project or `.cmux` config file path.
    public static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".cmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    /// Reads at most ``maxBytes`` + 1 bytes from one opened file descriptor.
    ///
    /// The extra byte lets the caller distinguish an accepted payload from an
    /// oversized one without ever materializing an unbounded replacement file.
    ///
    /// - Parameters:
    ///   - path: Regular-file path to read.
    ///   - maxBytes: Maximum payload size to accept.
    /// - Returns: Up to `maxBytes + 1` bytes, or `nil` when the descriptor/read
    ///   cannot be opened.
    static func boundedImageContents(atPath path: String, maxBytes: Int = maxImageBytes) -> Data? {
        guard maxBytes >= 0, maxBytes < Int.max,
              let handle = try? FileHandle(
                forReadingFrom: URL(fileURLWithPath: path, isDirectory: false)
              ) else {
            return nil
        }
        defer { try? handle.close() }

        let readLimit = maxBytes + 1
        var data = Data()
        data.reserveCapacity(readLimit)
        while data.count < readLimit {
            let remaining = readLimit - data.count
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: remaining)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private static func isSVGDocument(data: Data) -> Bool {
        let detector = SVGRootElementDetector()
        let parser = XMLParser(data: data)
        parser.delegate = detector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return detector.isSVG
    }

    private final class SVGRootElementDetector: NSObject, XMLParserDelegate {
        var isSVG = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let localName = String(elementName.split(separator: ":").last ?? "")
                .lowercased()
            isSVG = localName == "svg"
            parser.abortParsing()
        }
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
