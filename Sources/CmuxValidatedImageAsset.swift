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
        fileManager: FileManager = .default
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

        guard fileManager.fileExists(atPath: resolvedPath) else {
            return .failure(.missingFile)
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return .failure(.notRegularFile)
        }
        guard let data = fileManager.contents(atPath: resolvedPath) else {
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

        let inspector = SVGSecurityInspector()
        return inspector.parse(data: data)
    }

    private final class SVGSecurityInspector: NSObject, XMLParserDelegate {
        private var isSafe = true
        private var elementStack: [String] = []
        private var styleText: String?

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
            if loweredName == "style" {
                styleText = ""
            }
            if loweredName == "script" || loweredName == "foreignobject" {
                markUnsafe(parser)
                return
            }
            for (name, value) in attributeDict where !Self.isSafeSVGAttribute(name: name, value: value) {
                markUnsafe(parser)
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard !elementStack.isEmpty else { return }
            if elementStack.last == "style",
               let styleText,
               !Self.isSafeSVGStyle(styleText) {
                markUnsafe(parser)
                return
            }
            elementStack.removeLast()
            if elementStack.last != "style" {
                self.styleText = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard elementStack.last == "style" else { return }
            styleText?.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard elementStack.last == "style" else { return }
            guard let text = String(data: CDATABlock, encoding: .utf8) else {
                markUnsafe(parser)
                return
            }
            styleText?.append(text)
        }

        func parser(
            _ parser: XMLParser,
            foundProcessingInstructionWithTarget target: String,
            data: String?
        ) {
            if target.lowercased() == "xml-stylesheet" { markUnsafe(parser) }
        }

        private func markUnsafe(_ parser: XMLParser) {
            isSafe = false
            parser.abortParsing()
        }

        private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
            let loweredName = name.lowercased()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredValue = trimmedValue.lowercased()
            if loweredName.hasPrefix("on") { return false }
            if loweredName == "xmlns" || loweredName.hasPrefix("xmlns:") { return true }
            if loweredName == "href" || loweredName == "xlink:href" {
                return isSafeSVGReference(trimmedValue)
            }
            if containsBlockedSVGValue(loweredValue) { return false }
            return !loweredValue.contains("url(") || containsOnlyInternalSVGURLs(trimmedValue)
        }

        private static func isSafeSVGStyle(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            guard !loweredValue.contains("@import"),
                  !containsBlockedSVGValue(loweredValue) else { return false }
            return !loweredValue.contains("url(") || containsOnlyInternalSVGURLs(value)
        }

        private static func isSafeSVGReference(_ value: String) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return true }
            if trimmedValue.hasPrefix("#") { return true }
            if trimmedValue.lowercased().hasPrefix("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }
            return false
        }

        private static func containsBlockedSVGValue(_ value: String) -> Bool {
            ["javascript:", "data:", "http://", "https://", "file://", "blob:"]
                .contains { value.contains($0) }
        }

        private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            var searchStart = loweredValue.startIndex
            while let range = loweredValue.range(
                of: "url(", options: [], range: searchStart..<loweredValue.endIndex
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
                guard reference.hasPrefix("#") else { return false }
                searchStart = loweredValue.index(after: closing)
            }
            return true
        }
    }
}
