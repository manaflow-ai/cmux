/// The routes from New Tab pages to their key holds (the app's `NewTabInputCoordinator`), keyed by the hold's token: the
/// page's owner calls them, the input owner sets them.
public struct NewTabInputHooks {
    /// A first page took a key-hold token (the hold then waits for that page's readiness).
    public var firstPageToken: (@MainActor (String) -> Void)?
    /// A New Tab page that carries a key-hold token will never report its field ready (its load failed, it crashed
    /// past its reload budget, or its tab went): the hold of that token ends with the reason, whichever opening
    /// (Cmd-T, Cmd-N, a split) made it.
    public var ended: (@MainActor (String, WindowInputQueue.DropReason) -> Void)?

    public init() {}
}
