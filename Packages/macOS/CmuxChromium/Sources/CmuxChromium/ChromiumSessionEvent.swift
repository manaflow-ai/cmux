/// An event delivered by a Chromium session while the runtime pumps its message loop.
public enum ChromiumSessionEvent: Sendable, Equatable {
    /// The Content Shell host finished startup.
    ///
    /// `compositorContextID` is nonzero once the GPU compositor has exported a
    /// `CAContext`; create a `CALayerHost` with it to display web content.
    case ready(hostPID: Int32, compositorContextID: UInt32)
    /// The compositor exported a new `CAContext`; rehost the layer with this ID.
    case compositorChanged(contextID: UInt32)
    /// The visible page's URL, title, or loading state changed.
    case navigationChanged(url: String, title: String, isLoading: Bool)
    /// The shell's surface tree changed (popups, pickers, DevTools); payload is JSON.
    case surfaceTreeChanged(json: String)
    /// A diagnostic log line from the host process.
    case log(String)
    /// The Content Shell process disconnected; the session is unusable afterwards.
    case disconnected
}
