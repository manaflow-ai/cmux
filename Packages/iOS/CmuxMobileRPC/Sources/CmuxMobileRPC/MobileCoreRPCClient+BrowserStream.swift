public import CMUXMobileCore
import Foundation

extension MobileCoreRPCClient {
    /// Lists streamable browser panels in one workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    /// - Returns: The panels currently owned by that workspace.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func listMobileBrowserPanels(workspaceID: String) async throws -> [MobileBrowserPanelDescriptor] {
        let data = try await sendBrowserRequest(
            method: "mobile.browser.list",
            parameters: MobileBrowserListParameters(workspaceID: workspaceID)
        )
        return try MobileBrowserListResponse.decode(data).panels
    }

    /// Starts streaming one browser panel and returns its descriptor.
    /// - Parameters:
    ///   - panelID: The Mac browser panel identifier.
    ///   - viewport: Current phone viewport when the Mac supports stream reflow.
    /// - Returns: The descriptor accepted by the Mac for the new subscription.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func startMobileBrowserStream(
        panelID: String,
        viewport: MobileBrowserViewport? = nil
    ) async throws -> MobileBrowserPanelDescriptor {
        let data = try await sendBrowserRequest(
            method: "mobile.browser.stream.start",
            parameters: MobileBrowserStreamStartParameters(panelID: panelID, viewport: viewport)
        )
        return try JSONDecoder().decode(MobileBrowserPanelDescriptor.self, from: data)
    }

    /// Updates the phone viewport used to reflow an active browser stream.
    /// - Parameter parameters: Panel-scoped phone viewport report.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func updateMobileBrowserViewport(
        _ parameters: MobileBrowserViewportParameters
    ) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(method: "mobile.browser.viewport", parameters: parameters)
    }

    /// Stops streaming one browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func stopMobileBrowserStream(panelID: String) async throws -> MobileBrowserCommandResponse {
        let data = try await sendBrowserRequest(
            method: "mobile.browser.stream.stop",
            parameters: MobileBrowserPanelParameters(panelID: panelID)
        )
        return try MobileBrowserCommandResponse.decode(data)
    }

    /// Acknowledges the newest browser frame installed for display.
    /// - Parameters:
    ///   - panelID: The Mac browser panel identifier.
    ///   - sequence: The cumulative subscription-local sequence displayed by the phone.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func acknowledgeMobileBrowserFrame(panelID: String, sequence: UInt64) async throws -> MobileBrowserCommandResponse {
        let data = try await sendBrowserRequest(
            method: "mobile.browser.frame.ack",
            parameters: MobileBrowserFrameAckParameters(panelID: panelID, sequence: sequence)
        )
        return try MobileBrowserCommandResponse.decode(data)
    }

    /// Answers a mirrored native browser dialog.
    ///
    /// The response text can contain a password and is encoded directly into the RPC frame
    /// without being copied into logs or diagnostics.
    /// - Parameter response: Selected action and optional sensitive text.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func respondToMobileBrowserDialog(
        _ response: MobileBrowserDialogRespondParameters
    ) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(
            method: "mobile.browser.dialog.respond",
            parameters: response
        )
    }

    /// Replays pointer input against a Mac browser panel.
    /// - Parameter input: Page-point pointer input.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func sendMobileBrowserPointer(_ input: MobileBrowserPointerInput) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(method: "mobile.browser.input.pointer", parameters: input)
    }

    /// Replays native scroll input against a Mac browser panel.
    /// - Parameter input: Page-point scroll input with native gesture phase.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func sendMobileBrowserScroll(_ input: MobileBrowserScrollInput) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(method: "mobile.browser.input.scroll", parameters: input)
    }

    /// Replays a key against a Mac browser panel.
    /// - Parameter input: The key token and modifiers to replay.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func sendMobileBrowserKey(_ input: MobileBrowserKeyInput) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(method: "mobile.browser.input.key", parameters: input)
    }

    /// Inserts committed text into the focused Mac page element.
    /// - Parameter input: The committed text to insert.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func sendMobileBrowserText(_ input: MobileBrowserTextInput) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(method: "mobile.browser.input.text", parameters: input)
    }

    /// Navigates a Mac browser panel to a smart address.
    /// - Parameters:
    ///   - panelID: The Mac browser panel identifier.
    ///   - url: The address or search text interpreted by the Mac.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func navigateMobileBrowser(panelID: String, url: String) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(
            method: "mobile.browser.navigate",
            parameters: MobileBrowserNavigateParameters(panelID: panelID, url: url)
        )
    }

    /// Sends a back command to a Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func backMobileBrowser(panelID: String) async throws -> MobileBrowserCommandResponse {
        try await sendMobileBrowserPanelCommand(method: "mobile.browser.back", panelID: panelID)
    }

    /// Sends a forward command to a Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func forwardMobileBrowser(panelID: String) async throws -> MobileBrowserCommandResponse {
        try await sendMobileBrowserPanelCommand(method: "mobile.browser.forward", panelID: panelID)
    }

    /// Reloads a Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    /// - Returns: The Mac command acknowledgement.
    /// - Throws: A transport, authorization, RPC, or response-decoding error.
    public func reloadMobileBrowser(panelID: String) async throws -> MobileBrowserCommandResponse {
        try await sendMobileBrowserPanelCommand(method: "mobile.browser.reload", panelID: panelID)
    }

    private func sendMobileBrowserPanelCommand(method: String, panelID: String) async throws -> MobileBrowserCommandResponse {
        try await sendBrowserCommand(
            method: method,
            parameters: MobileBrowserPanelParameters(panelID: panelID)
        )
    }

    private func sendBrowserCommand<Parameters: Encodable>(
        method: String,
        parameters: Parameters
    ) async throws -> MobileBrowserCommandResponse {
        let data = try await sendBrowserRequest(method: method, parameters: parameters)
        return try MobileBrowserCommandResponse.decode(data)
    }

    private func sendBrowserRequest<Parameters: Encodable>(method: String, parameters: Parameters) async throws -> Data {
        try await sendRequest(MobileBrowserRPCRequestEncoder().requestData(method: method, parameters: parameters))
    }
}
