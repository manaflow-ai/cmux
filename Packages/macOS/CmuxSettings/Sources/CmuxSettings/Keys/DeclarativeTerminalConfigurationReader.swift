import Foundation

/// Decodes declarative terminal settings away from the main actor.
///
/// JSON parsing is intentionally isolated here so terminal creation consumes
/// only the already-published cache value. A reader is cheap to construct and
/// can be injected into tests or a settings runtime.
public actor DeclarativeTerminalConfigurationReader {
    private let sanitizer: JSONCSanitizer

    /// Creates a reader using the standard JSONC sanitizer.
    ///
    /// - Parameter sanitizer: Sanitizer for comments and trailing commas.
    public init(sanitizer: JSONCSanitizer = JSONCSanitizer()) {
        self.sanitizer = sanitizer
    }

    /// Decodes one coherent store revision into terminal settings.
    ///
    /// - Parameter revision: Immutable bytes from ``JSONConfigStore``.
    /// - Returns: Safe defaults for missing or invalid values.
    public func decode(
        _ revision: JSONConfigStoreSnapshot
    ) -> DeclarativeTerminalConfiguration.Snapshot {
        DeclarativeTerminalConfiguration.snapshot(
            data: revision.data,
            sanitizer: sanitizer
        )
    }
}
