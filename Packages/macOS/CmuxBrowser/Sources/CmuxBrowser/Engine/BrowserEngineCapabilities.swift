import Foundation

/// Features a browser engine supports.
///
/// Callers branch on capabilities, never on ``BrowserEngineKind``, so a
/// feature works on whichever engine gains it.
public struct BrowserEngineCapabilities: OptionSet, Hashable, Sendable {
    /// The raw bit set.
    public let rawValue: UInt32

    /// Creates a capability set from raw bits.
    /// - Parameter rawValue: The bit set.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// A developer tools inspector (``BrowserPage/showDevTools()``).
    public static let devTools = BrowserEngineCapabilities(rawValue: 1 << 0)
    /// Chrome DevTools Protocol access (``BrowserPage/sendDevToolsProtocolMessage(method:params:)``).
    public static let devToolsProtocol = BrowserEngineCapabilities(rawValue: 1 << 1)
    /// Real Chrome extensions.
    public static let extensions = BrowserEngineCapabilities(rawValue: 1 << 2)
    /// Trusted, non-synthetic input for automation (``BrowserPage/dispatchInput(_:)``).
    public static let trustedInput = BrowserEngineCapabilities(rawValue: 1 << 3)
    /// Engine-native find in page instead of the injected find script.
    public static let nativeFind = BrowserEngineCapabilities(rawValue: 1 << 4)
    /// Find in page reports a match count.
    public static let findMatchCount = BrowserEngineCapabilities(rawValue: 1 << 5)
    /// ``BrowserPage/takeSnapshot(rect:)`` returns page pixels.
    public static let snapshots = BrowserEngineCapabilities(rawValue: 1 << 6)
    /// Downloads are reported as ``BrowserPageEvent/downloadUpdated(_:)``.
    public static let downloads = BrowserEngineCapabilities(rawValue: 1 << 7)
    /// Element fullscreen stays inside the pane.
    public static let paneFullscreen = BrowserEngineCapabilities(rawValue: 1 << 8)
    /// Script access to cross-origin frames.
    public static let crossOriginFrames = BrowserEngineCapabilities(rawValue: 1 << 9)
    /// Request interception.
    public static let networkIntercept = BrowserEngineCapabilities(rawValue: 1 << 10)
    /// ``BrowserPage/addUserScript(_:)`` injects scripts into every document.
    public static let userScripts = BrowserEngineCapabilities(rawValue: 1 << 11)
    /// ``BrowserPage/isMuted`` mutes page audio.
    public static let mediaMuting = BrowserEngineCapabilities(rawValue: 1 << 12)
}
