/// A terminal identity that is unambiguous across multiple Macs.
///
/// Bare ``MobileTerminalPreview/ID`` strings are Mac-local: two Macs can both
/// report `"terminal-1"`. The render-grid byte-delivery and input paths must
/// route to the Mac that actually owns the terminal, so the scoped selection
/// and (in a later phase) the surface key are keyed on this pair.
///
/// Invariant: ``terminalID`` stays Mac-local (the wire id sent to that Mac's
/// RPC client) and ``deviceId`` only selects which client to send to — the two
/// are never crossed.
public struct ScopedTerminalID: Hashable, Sendable, Codable {
    /// The owning Mac's cmux device UUID (matches
    /// ``MobileTerminalPreview/deviceId``). `""` is the unscoped/single-Mac
    /// case.
    public var deviceId: String
    /// The Mac-local terminal identifier (the wire id).
    public var terminalID: MobileTerminalPreview.ID

    /// Creates a scoped terminal identity.
    /// - Parameters:
    ///   - deviceId: The owning Mac's cmux device UUID. Defaults to `""`.
    ///   - terminalID: The Mac-local terminal identifier.
    public init(deviceId: String = "", terminalID: MobileTerminalPreview.ID) {
        self.deviceId = deviceId
        self.terminalID = terminalID
    }

    /// The scoped identity for a terminal preview, taking its `deviceId` and
    /// `id` together.
    /// - Parameter terminal: The terminal whose scoped identity is wanted.
    public init(_ terminal: MobileTerminalPreview) {
        self.init(deviceId: terminal.deviceId, terminalID: terminal.id)
    }
}
