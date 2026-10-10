public import Foundation

/// Features an engine supports. Callers branch on capabilities, never on
/// engine kind (plans/cmux-next/browser.md section 3).
public nonisolated struct BrowserCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Chrome DevTools Protocol access to the tab.
    public static let cdp = BrowserCapabilities(rawValue: 1 << 0)
    /// Real Chrome extensions.
    public static let extensions = BrowserCapabilities(rawValue: 1 << 1)
    /// Trusted (non-synthetic) input events for automation.
    public static let trustedInput = BrowserCapabilities(rawValue: 1 << 2)
    /// Request interception.
    public static let networkIntercept = BrowserCapabilities(rawValue: 1 << 3)
    /// Script access to cross-origin frames.
    public static let crossOriginFrames = BrowserCapabilities(rawValue: 1 << 4)
    /// A developer tools inspector.
    public static let devTools = BrowserCapabilities(rawValue: 1 << 5)
    /// Downloads reported through `BrowserTabIntent.download`.
    public static let downloads = BrowserCapabilities(rawValue: 1 << 6)
    /// Element fullscreen stays inside the pane.
    public static let paneFullscreen = BrowserCapabilities(rawValue: 1 << 7)
    /// `snapshot()` returns page pixels.
    public static let snapshots = BrowserCapabilities(rawValue: 1 << 8)
    /// `find` reports a match count.
    public static let findMatchCount = BrowserCapabilities(rawValue: 1 << 9)
}

/// Whether an engine can create tabs in this process.
public nonisolated enum BrowserEngineAvailability: Hashable, Sendable {
    case available
    /// The engine cannot run; `reason` is a localized user-facing sentence.
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public nonisolated enum BrowserEngineError: Error, Hashable, Sendable {
    case engineNotRegistered(BrowserEngineKind)
    case engineUnavailable(BrowserEngineKind, reason: String)
    /// A configuration with a machine store (a proxied tab) asked for an
    /// engine other than Chromium. Only Chromium sends loopback requests to
    /// the store's proxy; any other engine would load this Mac's localhost.
    case machineStoreRequiresChromium
}
