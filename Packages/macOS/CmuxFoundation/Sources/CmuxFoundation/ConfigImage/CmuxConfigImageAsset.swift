public import Foundation
import CryptoKit
import os

/// A validated, resolved image asset referenced from a cmux config button icon
/// (`{"type":"image","path":...}`).
///
/// Construct it from a config-relative or absolute path with
/// ``init(path:relativeToConfig:globalConfigPath:)``; the initializer performs
/// the full resolve-and-validate pipeline (URL-scheme rejection, project-root
/// containment for project-local configs, byte-size cap, and SVG safety
/// inspection) and fails (returns `nil`) when the path is disallowed, missing,
/// too large, or contains unsafe SVG content. On success it holds the loaded
/// ``data``, its SHA-256 ``fingerprint``, and whether it came from a
/// project-local (non-global) config via ``isProjectLocal``.
public struct CmuxConfigImageAsset: Sendable {
    /// The raw bytes of the validated image file.
    public let data: Data

    /// Lowercase hex SHA-256 of ``data``, used to detect content changes.
    public let fingerprint: String

    /// `true` when the asset was resolved relative to a project-local config
    /// (a config other than the global one), which the app gates behind an
    /// explicit allow flag before rendering.
    public let isProjectLocal: Bool

    private static let maxImageBytes = 1_000_000

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "CmuxConfigImageAsset"
    )

    /// Resolves and validates the image at `path`, relative to the config file
    /// at `configSourcePath` (or treated as global when that equals
    /// `globalConfigPath` / is `nil`). Returns `nil` when the path is rejected,
    /// the file does not exist, exceeds the size cap, or is an unsafe SVG.
    public init?(
        path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) {
        guard let resolvedPath = Self.safeResolvedImagePath(
            path,
            relativeToConfig: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: resolvedPath) else {
            Self.logger.log("icon image does not exist: \(resolvedPath, privacy: .public)")
            return nil
        }
        guard data.count <= Self.maxImageBytes else {
            Self.logger.log("icon image is too large: \(resolvedPath, privacy: .public)")
            return nil
        }
        if Self.looksLikeSVGPath(resolvedPath), !Self.isSafeSVG(data: data) {
            Self.logger.log("icon SVG contains unsupported content: \(resolvedPath, privacy: .public)")
            return nil
        }

        let isProjectLocal = configSourcePath != nil && configSourcePath != globalConfigPath
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.data = data
        self.fingerprint = fingerprint
        self.isProjectLocal = isProjectLocal
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

        let imagePath = configSourcePath.map(CmuxConfigImagePath.init(configSourcePath:))
        let resolvedPath = imagePath.resolve(trimmed)
        guard !resolvedPath.isEmpty else { return nil }
        let standardizedPath = (resolvedPath as NSString).standardizingPath

        guard !isGlobal, let imagePath else {
            return standardizedPath
        }

        let allowedRoot = imagePath.projectRoot
        let resolvedURL = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath()
        let allowedURL = URL(fileURLWithPath: allowedRoot).resolvingSymlinksInPath()
        let resolved = resolvedURL.path
        let allowed = allowedURL.path
        guard resolved == allowed || resolved.hasPrefix(allowed + "/") else {
            return nil
        }
        return resolved
    }

    /// XML-parser-backed SVG safety inspector. Rejects scriptable elements
    /// (`script`, `foreignObject`), `on*` event-handler attributes, external
    /// references (non-fragment `href`/`xlink:href`, `url(...)` to anything but
    /// internal `#` fragments), blocked URL schemes, and `@import`/external
    /// stylesheet directives. Aborts parsing on the first violation.
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
}
