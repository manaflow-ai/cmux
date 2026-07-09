/// Localized error message text passed into plan realization from the app.
///
/// Localization must stay app-side: `String(localized:)` resolved inside this
/// package would bind to the package bundle (which lacks the `browser.import.error.*`
/// keys) and silently drop every non-English translation. The app resolves these
/// strings in its own bundle and passes them through this seam so realization
/// failures surface faithfully localized messages.
public struct BrowserImportRealizationStrings: Sendable {
    /// Message shown when a selected destination profile no longer exists.
    public let destinationMissing: String
    /// `String(format:)` template (with one `%@`) for a failed profile creation,
    /// interpolated with the requested destination name.
    public let destinationCreateFailedFormat: String

    /// Creates the realization strings bundle.
    ///
    /// - Parameters:
    ///   - destinationMissing: Message for a missing destination profile.
    ///   - destinationCreateFailedFormat: `%@` format template for a failed creation.
    public init(destinationMissing: String, destinationCreateFailedFormat: String) {
        self.destinationMissing = destinationMissing
        self.destinationCreateFailedFormat = destinationCreateFailedFormat
    }
}
