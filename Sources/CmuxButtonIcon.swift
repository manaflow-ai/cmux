import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Button Icons
enum CmuxButtonIcon: Codable, Sendable, Hashable {
    case symbol(String)
    case emoji(String, scale: Double = 1)
    case imagePath(String)

    var symbolName: String {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

    func bonsplitIcon(
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

    func projectLocalImageFingerprint(configSourcePath: String?, globalConfigPath: String) -> String? {
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

    private func resolvingRelativeImagePath(relativeToConfig configSourcePath: String?) -> CmuxButtonIcon {
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

    private static func looksLikeSVGPath(_ value: String) -> Bool {
        (value as NSString).pathExtension.lowercased() == "svg"
    }

    private static func isSafeSVG(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"),
              !lowered.contains("<!entity") else {
            return false
        }

        let inspector = SVGSecurityInspector()
        return inspector.parse(data: data)
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
        if looksLikeSVGPath(resolvedPath), !isSafeSVG(data: data) {
            NSLog("[CmuxConfig] icon SVG contains unsupported content: %@", resolvedPath)
            return nil
        }

        let isProjectLocal = configSourcePath != nil && configSourcePath != globalConfigPath
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PreparedImageAsset(data: data, fingerprint: fingerprint, isProjectLocal: isProjectLocal)
    }

    static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".cmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    private final class SVGSecurityInspector: NSObject, XMLParserDelegate {
        private var isSafe = true
        private var elementStack: [String] = []

        func parse(data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            let parsed = parser.parse()
            return parsed && isSafe
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let loweredName = elementName.lowercased()
            elementStack.append(loweredName)

            if loweredName == "script" || loweredName == "foreignobject" {
                markUnsafe(parser)
                return
            }

            for (name, value) in attributeDict {
                guard Self.isSafeSVGAttribute(name: name, value: value) else {
                    markUnsafe(parser)
                    return
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard !elementStack.isEmpty else { return }
            elementStack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard elementStack.last == "style" else { return }
            guard Self.isSafeSVGStyle(string) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard elementStack.last == "style",
                  let text = String(data: CDATABlock, encoding: .utf8) else {
                return
            }
            guard Self.isSafeSVGStyle(text) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            foundProcessingInstructionWithTarget target: String,
            data: String?
        ) {
            if target.lowercased() == "xml-stylesheet" {
                markUnsafe(parser)
            }
        }

        private func markUnsafe(_ parser: XMLParser) {
            isSafe = false
            parser.abortParsing()
        }

        private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
            let loweredName = name.lowercased()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredValue = trimmedValue.lowercased()

            if loweredName.hasPrefix("on") {
                return false
            }

            if loweredName == "xmlns" || loweredName.hasPrefix("xmlns:") {
                return true
            }

            if loweredName == "href" || loweredName == "xlink:href" {
                return isSafeSVGReference(trimmedValue)
            }

            if containsBlockedSVGValue(loweredValue) {
                return false
            }

            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }

            return true
        }

        private static func isSafeSVGStyle(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            guard !loweredValue.contains("@import"),
                  !containsBlockedSVGValue(loweredValue) else {
                return false
            }
            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(value)
            }
            return true
        }

        private static func isSafeSVGReference(_ value: String) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return true }
            if trimmedValue.hasPrefix("#") {
                return true
            }
            if trimmedValue.lowercased().hasPrefix("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }
            return false
        }

        private static func containsBlockedSVGValue(_ value: String) -> Bool {
            let blockedFragments = [
                "javascript:",
                "data:",
                "http://",
                "https://",
                "file://",
                "blob:"
            ]
            return blockedFragments.contains { value.contains($0) }
        }

        private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            var searchStart = loweredValue.startIndex

            while let range = loweredValue.range(
                of: "url(",
                options: [],
                range: searchStart..<loweredValue.endIndex
            ) {
                let contentStart = range.upperBound
                guard let closing = loweredValue[contentStart...].firstIndex(of: ")") else {
                    return false
                }

                var reference = String(loweredValue[contentStart..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if (reference.hasPrefix("\"") && reference.hasSuffix("\"")) ||
                    (reference.hasPrefix("'") && reference.hasSuffix("'")) {
                    reference.removeFirst()
                    reference.removeLast()
                }

                guard reference.hasPrefix("#") else {
                    return false
                }

                searchStart = loweredValue.index(after: closing)
            }

            return true
        }
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

