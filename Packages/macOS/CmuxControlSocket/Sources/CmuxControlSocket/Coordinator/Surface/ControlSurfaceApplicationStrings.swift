public import Foundation

/// App-bundle-resolved strings for application-surface request validation.
///
/// These values resolve in the app conformance so the socket package does not
/// bind localization lookups to its own bundle.
public struct ControlSurfaceApplicationStrings: Sendable, Equatable {
    /// Error returned when application surfaces are requested as pane splits.
    public let splitUnsupported: String
    /// Error returned for a missing or invalid source window identifier.
    public let invalidWindowID: String
    /// Error returned for a missing or invalid source process identifier.
    public let invalidProcessID: String
    /// Error returned for a capture frame rate outside the supported range.
    public let invalidFrameRate: String

    /// Creates the localized application-surface validation strings.
    public init(
        splitUnsupported: String,
        invalidWindowID: String,
        invalidProcessID: String,
        invalidFrameRate: String
    ) {
        self.splitUnsupported = splitUnsupported
        self.invalidWindowID = invalidWindowID
        self.invalidProcessID = invalidProcessID
        self.invalidFrameRate = invalidFrameRate
    }
}
