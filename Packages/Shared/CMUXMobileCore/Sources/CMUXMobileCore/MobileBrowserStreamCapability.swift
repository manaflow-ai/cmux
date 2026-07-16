/// Capability advertised by a Mac that supports browser-pane streaming.
public struct MobileBrowserStreamCapability: Sendable {
    private init() {}

    /// Version-one browser streaming capability identifier.
    public static let identifier = "browser.stream.v1"
}
