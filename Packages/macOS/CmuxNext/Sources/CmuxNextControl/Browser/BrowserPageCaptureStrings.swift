import Foundation

/// Localized errors for control-socket browser captures and wake attempts.
public struct BrowserPageCaptureStrings: Sendable {
    /// Uses the control domain's translated string catalog.
    public init() {}

    /// A page snapshot failed.
    public func captureFailed(_ reason: String) -> String {
        String(format: String(localized: "handlers.browserPage.captureFailed", defaultValue: "The page could not be captured (%@); show the tab and retry",
                              bundle: .module), reason)
    }

    /// A hibernated page did not wake in time.
    public var wakeFailed: String {
        String(localized: "handlers.browserPage.wakeFailed", defaultValue: "The hibernated page did not wake in time; retry", bundle: .module)
    }

    /// Image encoding failed.
    public var encodeFailed: String {
        String(localized: "handlers.browserPage.encodeFailed", defaultValue: "The screenshot could not be encoded as PNG", bundle: .module)
    }

    /// A capture could not be written to its output directory.
    public func saveFailed(_ reason: String) -> String {
        String(format: String(localized: "handlers.browserPage.saveFailed", defaultValue: "The screenshot could not be saved: %@", bundle: .module), reason)
    }

    /// The requested clip misses the captured viewport.
    public var clipOutside: String {
        String(localized: "handlers.browserPage.clipOutside", defaultValue: "The element is outside the captured viewport", bundle: .module)
    }
}
