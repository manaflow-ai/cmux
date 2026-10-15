import Foundation

/// Picks the engine for a browser panel created by any entrypoint.
///
/// The order is: an explicit request, then an inherited engine, then the
/// `browser.engine` setting.
///
/// - An explicit request for an unavailable engine is refused with the
///   reason. Automation that asked for Chromium never silently gets WebKit.
/// - An inherited or configured Chromium that is unavailable opens WebKit
///   and reports the reason as ``BrowserEngineChoice/fallback`` so the panel
///   shows a notice.
///
/// ```swift
/// let resolution = BrowserEngineResolver().resolve(
///     requested: BrowserEngineKind(requestValue: cliEngine),
///     inherited: nil,
///     setting: .chromium,
///     availability: { registry.availability(for: $0) }
/// )
/// ```
public struct BrowserEngineResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    /// Resolves the engine for a new panel.
    /// - Parameters:
    ///   - requested: The engine the open request named, or `nil`.
    ///   - inherited: The engine of the opener, restored record or duplicated
    ///     panel, or `nil`.
    ///   - setting: The `browser.engine` setting value.
    ///   - availability: Reports whether an engine can create pages now.
    /// - Returns: The engine to open with, or a refusal for an explicit
    ///   request that cannot be honored.
    public func resolve(
        requested: BrowserEngineKind?,
        inherited: BrowserEngineKind?,
        setting: BrowserEngineKind,
        availability: (BrowserEngineKind) -> BrowserEngineAvailability
    ) -> BrowserEngineResolution {
        if let requested {
            if let reason = availability(requested).unavailableReason {
                return .refuse(requested, reason)
            }
            return .open(BrowserEngineChoice(engine: requested, source: .explicit))
        }
        let wanted: BrowserEngineKind
        let source: BrowserEngineChoiceSource
        if let inherited {
            (wanted, source) = (inherited, .inherited)
        } else {
            (wanted, source) = (setting, .setting)
        }
        // WebKit is always available; only another engine can fall back.
        guard wanted != .webkit, let reason = availability(wanted).unavailableReason else {
            return .open(BrowserEngineChoice(engine: wanted, source: source))
        }
        return .open(BrowserEngineChoice(engine: .webkit, fallback: reason, source: source))
    }
}
