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
}
