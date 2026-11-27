public import Foundation

/// Where a link from a remote terminal may open.
public struct RemoteLinkDestinations: Equatable, Sendable {
    /// The URL for the cmux browser, or `nil` when the link must not open there.
    public var browserURL: URL?
    /// The URL for the default browser, or `nil` when the link must not open there.
    public var externalURL: URL?

    /// Creates a destination pair.
    public init(browserURL: URL?, externalURL: URL?) {
        self.browserURL = browserURL
        self.externalURL = externalURL
    }
}
