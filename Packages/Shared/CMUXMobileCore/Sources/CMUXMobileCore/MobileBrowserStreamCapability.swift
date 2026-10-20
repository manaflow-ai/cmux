/// Capability advertised by a Mac that supports browser-pane streaming.
public struct MobileBrowserStreamCapability: Sendable {
    private init() {}

    /// Version-one browser streaming capability identifier.
    public static let identifier = "browser.stream.v1"
    /// Version-one browser stream viewport-reflow capability identifier.
    public static let viewportIdentifier = "browser.stream.viewport.v1"
    /// Version-one native browser dialog mirroring capability identifier.
    public static let dialogIdentifier = "browser.stream.dialog.v1"
    /// Version-one phone-initiated browser panel creation capability identifier.
    public static let createIdentifier = "browser.stream.create.v1"
}
