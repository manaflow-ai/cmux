public import Foundation

/// App-bundle-resolved strings for application-surface request validation.
///
/// These values resolve in the app conformance so the socket package does not
/// bind localization lookups to its own bundle.
public struct ControlSurfaceApplicationStrings: Sendable, Equatable {
    public let splitUnsupported: String
    public let invalidWindowID: String
    public let invalidProcessID: String
    public let invalidFrameRate: String

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
