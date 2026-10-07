/// The app's browser tabs as the phone may see them (the app implements
/// this over its tab model and engines; tests use a fake).
public protocol BrowserPageHost: Sendable {
    /// Attaches to a browser tab of this host. Throws
    /// `BrowserPageError.tabNotFound` for an id that is not a browser tab here.
    func attach(_ request: BrowserAttachRequest) async throws -> any BrowserPageAttachment
}
