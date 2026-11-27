public import CMUXMobileCore

/// Async RPC actions emitted by browser stream chrome and input views.
public struct BrowserStreamSurfaceActions: Sendable {
    /// Sends a pointer event.
    public let pointer: @Sendable (MobileBrowserPointerInput) async -> Void
    /// Sends a scroll event.
    public let scroll: @Sendable (MobileBrowserScrollInput) async -> Void
    /// Sends a key event.
    public let key: @Sendable (MobileBrowserKeyInput) async -> Void
    /// Sends committed text.
    public let text: @Sendable (MobileBrowserTextInput) async -> Void
    /// Reports a changed phone viewport.
    public let viewport: @Sendable (MobileBrowserViewportParameters) async -> Void
    /// Navigates to a user-entered address.
    public let navigate: @Sendable (_ panelID: String, _ url: String) async -> Void
    /// Navigates backward.
    public let back: @Sendable (_ panelID: String) async -> Void
    /// Navigates forward.
    public let forward: @Sendable (_ panelID: String) async -> Void
    /// Reloads the page.
    public let reload: @Sendable (_ panelID: String) async -> Void
    /// Answers a mirrored native browser dialog.
    public let respondToDialog: @Sendable (MobileBrowserDialogRespondParameters) async -> Void

    /// Creates a complete action sink.
    /// - Parameters:
    ///   - pointer: Sends page-point pointer input.
    ///   - scroll: Sends page-point scroll input.
    ///   - key: Sends a key token and modifiers.
    ///   - text: Sends committed text.
    ///   - viewport: Reports the phone viewport used to reflow the Mac page.
    ///   - navigate: Navigates a panel to a smart address.
    ///   - back: Navigates a panel backward.
    ///   - forward: Navigates a panel forward.
    ///   - reload: Reloads a panel.
    ///   - respondToDialog: Answers a mirrored native browser dialog.
    public init(
        pointer: @escaping @Sendable (MobileBrowserPointerInput) async -> Void,
        scroll: @escaping @Sendable (MobileBrowserScrollInput) async -> Void,
        key: @escaping @Sendable (MobileBrowserKeyInput) async -> Void,
        text: @escaping @Sendable (MobileBrowserTextInput) async -> Void,
        viewport: @escaping @Sendable (MobileBrowserViewportParameters) async -> Void,
        navigate: @escaping @Sendable (String, String) async -> Void,
        back: @escaping @Sendable (String) async -> Void,
        forward: @escaping @Sendable (String) async -> Void,
        reload: @escaping @Sendable (String) async -> Void,
        respondToDialog: @escaping @Sendable (MobileBrowserDialogRespondParameters) async -> Void
    ) {
        self.pointer = pointer
        self.scroll = scroll
        self.key = key
        self.text = text
        self.viewport = viewport
        self.navigate = navigate
        self.back = back
        self.forward = forward
        self.reload = reload
        self.respondToDialog = respondToDialog
    }
}
