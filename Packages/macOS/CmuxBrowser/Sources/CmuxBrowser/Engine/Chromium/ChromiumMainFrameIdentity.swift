/// Owns the Chromium main-frame identity shared by navigation policy and pane loading state.
@MainActor
final class ChromiumMainFrameIdentity {
    private var frameID: String?

    /// Seeds the identity from `Page.getFrameTree`.
    func record(frameTree: CDPJSONValue) {
        frameID = frameTree.objectValue?["frameTree"]?
            .objectValue?["frame"]?
            .objectValue?["id"]?
            .stringValue
    }

    /// Updates the identity when Chromium reports a top-level frame navigation.
    func observe(_ event: CDPEvent) {
        guard event.method == "Page.frameNavigated",
              let frame = event.parameters["frame"]?.objectValue,
              frame["parentId"] == nil,
              let nextFrameID = frame["id"]?.stringValue else {
            return
        }
        frameID = nextFrameID
    }

    /// Returns whether a CDP frame identifier belongs to the current top-level frame.
    func matches(frameID candidate: String?) -> Bool {
        candidate != nil && candidate == frameID
    }
}
