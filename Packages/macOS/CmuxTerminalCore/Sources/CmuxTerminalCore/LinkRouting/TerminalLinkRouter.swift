import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Routes a link activated inside a terminal to the embedded browser or the
/// system.
///
/// Routing precedence: absolute file-system paths open externally; `http` and
/// `https` URLs open embedded when the injected ``BrowserHostNormalizing``
/// accepts their host, externally otherwise; other schemes open externally;
/// browser-navigable scheme-less text opens embedded; terminal path fragments
/// that did not already resolve through the caller's file-path pass are
/// ignored.
public struct TerminalLinkRouter: Sendable {
    private let hostNormalizer: any BrowserHostNormalizing

    /// Creates a router that validates web hosts through the browser domain.
    ///
    /// - Parameter hostNormalizer: The browser-domain host validation seam.
    public init(hostNormalizer: any BrowserHostNormalizing) {
        self.hostNormalizer = hostNormalizer
    }

    /// Resolves raw link text into an open target.
    ///
    /// - Parameter rawValue: The raw link text from the runtime or UI.
    /// - Returns: The routing decision, or `nil` for empty or unparseable
    ///   text.
    public func resolveOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        logDebugEvent("link.resolve input=\(trimmed)")
        #endif
        guard !trimmed.isEmpty else {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (empty)")
            #endif
            return nil
        }

        if NSString(string: trimmed).isAbsolutePath {
            #if DEBUG
            logDebugEvent("link.resolve result=external(absolutePath) url=\(trimmed)")
            #endif
            return .external(URL(fileURLWithPath: trimmed))
        }

        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return routeWebURL(parsed, reason: "explicit")
            }
            if scheme == "file" || scheme == "mailto" || trimmed.contains("://") {
                #if DEBUG
                logDebugEvent("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
                #endif
                return .external(parsed)
            }
        }

        if Self.looksLikeUnresolvedFileLineReference(trimmed) {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (fileLine)")
            #endif
            return nil
        }

        if Self.looksLikeWrappedFilePathFragment(trimmed) {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (pathFragment)")
            #endif
            return nil
        }

        if let webURL = hostNormalizer.navigableWebURL(trimmed),
           let scheme = webURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return routeWebURL(webURL, reason: "browser")
        }

        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased() {
            #if DEBUG
            logDebugEvent("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
            #endif
            return .external(parsed)
        }

        #if DEBUG
        logDebugEvent("link.resolve result=nil (unresolved)")
        #endif
        return nil
    }

    private func routeWebURL(_ url: URL, reason: String) -> TerminalOpenURLTarget {
        guard hostNormalizer.normalizedHost(url.host ?? "") != nil else {
            #if DEBUG
            logDebugEvent("link.resolve result=external(\(reason),invalidHost) url=\(url)")
            #endif
            return .external(url)
        }
        #if DEBUG
        logDebugEvent("link.resolve result=embeddedBrowser(\(reason)) url=\(url)")
        #endif
        return .embeddedBrowser(url)
    }

    private static func looksLikeUnresolvedFileLineReference(_ value: String) -> Bool {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let fileReference = fileReferenceBeforeLocationSuffix(value),
              let fileExtension = knownFileExtension(fileReference) else {
            return false
        }
        if fileReference.contains("/") { return true }
        if fileReference.contains(where: \.isUppercase) { return true }
        if Self.commonSourceBasenames.contains(stem(fileReference)) { return true }
        if Self.fileExtensionTopLevelDomains.contains(fileExtension),
           let port = trailingNumericSuffix(value),
           hasSingleLocationSuffix(value, after: fileReference),
           isPlausibleFileLikeHostPort(port) {
            return false
        }
        return true
    }

    private static func fileReferenceBeforeLocationSuffix(_ value: String) -> Substring? {
        guard let lastColon = value.lastIndex(of: ":"),
              lastColon < value.index(before: value.endIndex),
              value[value.index(after: lastColon)...].allSatisfy(\.isNumber) else {
            return nil
        }
        let beforeLastColon = value[..<lastColon]
        if let lineColon = beforeLastColon.lastIndex(of: ":"),
           lineColon < beforeLastColon.index(before: beforeLastColon.endIndex),
           beforeLastColon[beforeLastColon.index(after: lineColon)...].allSatisfy(\.isNumber) {
            return beforeLastColon[..<lineColon]
        }
        return beforeLastColon
    }

    private static func looksLikeWrappedFilePathFragment(_ value: String) -> Bool {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let slash = value.firstIndex(of: "/"),
              slash > value.startIndex else {
            return false
        }
        let hostCandidate = value[..<slash].lowercased()
        guard hostCandidate != "localhost" else { return false }
        guard hostCandidate.count == 1,
              hostCandidate.rangeOfCharacter(from: CharacterSet(charactersIn: ".:[]")) == nil else {
            return false
        }
        let pathStart = value.index(after: slash)
        let pathEnd = value[pathStart...].firstIndex { character in
            character == "?" || character == "#"
        } ?? value.endIndex
        let path = value[pathStart..<pathEnd]
        let lastComponentStart = path.lastIndex(of: "/").map(path.index(after:)) ?? path.startIndex
        let lastComponent = path[lastComponentStart...]
        // The Ghostty callback gives Swift only selected text, not the click
        // pin or wrapped logical line. Keep the fail-closed guard to the
        // reported wrapped suffix shape instead of all one-letter hosts.
        return knownFileExtension(lastComponent) == "md" && lastComponent.contains("-")
    }

    private static func knownFileExtension(_ value: some StringProtocol) -> String? {
        guard let dot = value.lastIndex(of: "."),
              dot < value.index(before: value.endIndex) else {
            return nil
        }
        let fileExtension = value[value.index(after: dot)...].lowercased()
        switch fileExtension {
        case "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java",
             "js", "jsx", "json", "m", "md", "mm", "php", "py", "rb", "rs",
             "sh", "swift", "toml", "ts", "tsx", "txt", "yaml", "yml", "zsh":
            return fileExtension
        default:
            return nil
        }
    }

    private static func stem(_ value: some StringProtocol) -> String {
        guard let dot = value.lastIndex(of: ".") else { return value.lowercased() }
        return value[..<dot].lowercased()
    }

    private static func trailingNumericSuffix(_ value: String) -> Substring? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        return value[value.index(after: colon)...]
    }

    private static func hasSingleLocationSuffix(
        _ value: String,
        after fileReference: some StringProtocol
    ) -> Bool {
        guard let colon = value.lastIndex(of: ":") else { return false }
        return value[..<colon].elementsEqual(fileReference)
    }

    private static func isPlausibleFileLikeHostPort(_ value: some StringProtocol) -> Bool {
        guard let port = UInt16(value) else { return false }
        // Bare `name.ext:number` is ambiguous when ext is also a TLD. Explicit
        // schemes route before this guard; keep low diagnostic-like line
        // numbers fail-closed while preserving common web/dev port shapes.
        return port == 80 || port == 443 || port >= 500
    }

    private static let commonSourceBasenames: Set<String> = [
        "app", "build", "changelog", "config", "foo", "index", "lib", "main",
        "package", "readme", "script", "server", "utils",
    ]

    private static let fileExtensionTopLevelDomains: Set<String> = [
        "cc", "md", "mm", "py", "rs", "sh",
    ]
}
