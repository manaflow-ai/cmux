import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Routes a link activated inside a terminal to the embedded browser or the
/// system.
///
/// Routing precedence, preserved exactly from the legacy resolver: absolute
/// file-system paths open externally; `http`/`https` URLs open embedded when
/// the injected ``BrowserHostNormalizing`` accepts their host, externally
/// otherwise; other schemes open externally; scheme-less text that the
/// browser can navigate (bare domains, localhost) opens embedded subject to
/// the same host check; anything else falls back to an external URL when it
/// parses at all.
///
/// Scheme-less text is a web link only when its host is `localhost`, an IP
/// address with a port, or a dotted name under a public top-level domain.
/// Anything else (`build-fleet/ORG-BACKUP.md`) is a path that named no file,
/// so it resolves to nothing rather than a browser at a bogus host.
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

        if !Self.hasExplicitScheme(trimmed),
           let webURL = hostNormalizer.navigableWebURL(trimmed),
           !isLinkableSchemelessHost(webURL) {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (schemeless non-public host) url=\(webURL)")
            #endif
            return nil
        }

        // Foundation parses `localhost:8000` as a custom URL scheme. Let the
        // browser's host/port resolver recognize it before dispatching schemes.
        if let webURL = hostNormalizer.navigableWebURL(trimmed),
           let scheme = webURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            guard hostNormalizer.normalizedHost(webURL.host ?? "") != nil else {
                return .external(webURL)
            }
            return .embeddedBrowser(webURL)
        }

        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                guard hostNormalizer.normalizedHost(parsed.host ?? "") != nil else {
                    #if DEBUG
                    logDebugEvent("link.resolve result=external(invalidHost) url=\(parsed)")
                    #endif
                    return .external(parsed)
                }
                #if DEBUG
                logDebugEvent("link.resolve result=embeddedBrowser url=\(parsed)")
                #endif
                return .embeddedBrowser(parsed)
            }
            #if DEBUG
            logDebugEvent("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
            #endif
            return .external(parsed)
        }

        if let webURL = hostNormalizer.navigableWebURL(trimmed) {
            guard hostNormalizer.normalizedHost(webURL.host ?? "") != nil else {
                #if DEBUG
                logDebugEvent("link.resolve result=external(bareHost-invalidHost) url=\(webURL)")
                #endif
                return .external(webURL)
            }
            #if DEBUG
            logDebugEvent("link.resolve result=embeddedBrowser(bareHost) url=\(webURL)")
            #endif
            return .embeddedBrowser(webURL)
        }

        guard let fallback = URL(string: trimmed) else {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (unparseable)")
            #endif
            return nil
        }
        #if DEBUG
        logDebugEvent("link.resolve result=external(fallback) url=\(fallback)")
        #endif
        return .external(fallback)
    }

    /// Whether the text starts with a URL scheme (`https:`, `mailto:`). A
    /// colon before a digit is a port (`localhost:8000`), not a scheme.
    private static func hasExplicitScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return false
        }
        let next = text.index(after: colon)
        return next == text.endIndex || !text[next].isNumber
    }

    /// Whether a scheme-less link's host can be a web host: localhost, an IP
    /// address with a port, or a dotted name under a public top-level domain.
    private func isLinkableSchemelessHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        if isIPv4 || host.contains(":") { return url.port != nil }
        guard labels.count >= 2, let last = labels.last, !last.isEmpty,
              !labels.contains(where: \.isEmpty) else { return false }
        return hostNormalizer.isPublicTopLevelDomain(String(last))
    }
}
