public import CMUXMobileCore
public import Foundation

/// Narrow event sink used by the shell without exposing browser-store internals.
@MainActor
public protocol BrowserStreamEventReceiving: AnyObject {
    /// Replaces panel discovery for one workspace.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - descriptors: The workspace's current browser panels.
    func replaceBrowserPanels(in workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor])
    /// Marks a stream active after the Mac accepts `stream.start`.
    /// - Parameter descriptor: The descriptor returned by the start request.
    func browserStreamDidStart(_ descriptor: MobileBrowserPanelDescriptor)
    /// Resets subscription-local sequencing immediately before `stream.start`.
    /// - Parameter panelID: The Mac browser panel identifier.
    func browserStreamWillStart(panelID: String) async
    /// Returns active selections that must be replayed after recovery.
    /// - Returns: The currently selected workspace and panel pairs.
    func activeBrowserStreamSelections() -> [BrowserStreamSelection]
    /// Applies shell connection status to active panels.
    /// - Parameter status: The current shell connection status.
    func setBrowserStreamConnectionStatus(_ status: BrowserStreamSurfaceState.ConnectionStatus)
    /// Marks active streams paused after background stop requests.
    func pauseBrowserStreams()
    /// Routes a raw `browser.frame` payload into the frame pipeline.
    /// - Parameters:
    ///   - payload: The raw event payload.
    ///   - acknowledge: Called after an accepted frame is installed for display.
    func receiveBrowserFramePayload(_ payload: Data, acknowledge: @escaping BrowserStreamFrameAcknowledging)
    /// Routes a raw `browser.state` payload into panel state.
    /// - Parameter payload: The raw event payload.
    func receiveBrowserStatePayload(_ payload: Data)
    /// Routes a raw `browser.dialog` payload into panel state.
    /// - Parameter payload: Raw event payload.
    func receiveBrowserDialogPayload(_ payload: Data)
    /// Routes a raw `browser.dialog.resolved` payload into panel state.
    /// - Parameter payload: Raw event payload.
    func receiveBrowserDialogResolvedPayload(_ payload: Data)
    /// Claims the visible dialog before its response RPC is sent.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string being answered.
    /// - Returns: The claimed dialog, or `nil` when it was already resolved.
    func beginBrowserDialogResponse(panelID: String, dialogID: String) -> MobileBrowserDialogEvent?
    /// Restores a dialog after a response transport failure.
    /// - Parameter dialog: Previously claimed dialog.
    func restoreBrowserDialog(_ dialog: MobileBrowserDialogEvent)
    /// Routes a raw `browser.closed` payload and returns the closed panel identifier.
    /// - Parameter payload: The raw event payload.
    /// - Returns: The decoded closed panel identifier, or `nil` for malformed data.
    func receiveBrowserClosedPayload(_ payload: Data) -> String?
    /// Configures the hook the liveness watchdog uses to re-arm a stream.
    /// - Parameter restart: Re-arms one panel's stream subscription.
    func configureBrowserStreamRestart(_ restart: @escaping @MainActor (String) async -> Void)
    /// Records forwarded user input for unanswered-input liveness tracking.
    /// - Parameter panelID: The Mac browser panel identifier.
    func noteBrowserInputSent(panelID: String)
    /// Records the latest phone viewport measured for a browser panel.
    /// - Parameter parameters: Panel-scoped phone viewport report.
    func reportBrowserStreamViewport(_ parameters: MobileBrowserViewportParameters)
    /// Returns the latest phone viewport measured for a browser panel.
    /// - Parameter panelID: Mac browser panel identifier.
    /// - Returns: The current viewport, or `nil` before the surface is laid out.
    func browserStreamViewport(for panelID: String) -> MobileBrowserViewport?
}

/// Acknowledges a frame after its decoded image was installed for display.
public typealias BrowserStreamFrameAcknowledging = @Sendable (_ panelID: String, _ sequence: UInt64) async -> Void
