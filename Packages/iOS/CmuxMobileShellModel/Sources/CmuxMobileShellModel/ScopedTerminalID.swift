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

    /// The separator between the device id and the Mac-local terminal id in an
    /// encoded ``surfaceKey``. `#` never appears in a cmux device UUID or a
    /// panel/terminal id, so the split is unambiguous; the first occurrence
    /// splits, and a terminal id that somehow contained one would keep its tail
    /// intact.
    public static let surfaceKeySeparator: Character = "#"

    /// The opaque, Mac-disambiguated surface key used as the dictionary key in
    /// the composite's `*BySurfaceID` byte-delivery maps and as the surface
    /// identity the terminal kit holds (`hostSurfaceID`, the output stream key).
    ///
    /// Encoded as `"<deviceId>#<terminalID>"`. Two Macs reporting the same bare
    /// `terminalID` therefore produce distinct surface keys, so render-grid
    /// bytes and input can never route to the wrong Mac's surface. The wire id
    /// sent to a Mac's RPC stays the bare ``terminalID`` — only the local key is
    /// scoped. An unscoped (`""`) device id yields `"#<terminalID>"`, which is
    /// still a stable distinct key for the single-Mac/preview case.
    public var surfaceKey: String {
        "\(deviceId)\(Self.surfaceKeySeparator)\(terminalID.rawValue)"
    }

    /// Decode a ``surfaceKey`` back into its `(deviceId, terminalID)` pair.
    ///
    /// Splits on the FIRST ``surfaceKeySeparator`` so a device id is recovered
    /// exactly and any separator in the (Mac-local) terminal tail is preserved.
    /// A string with no separator is treated as an unscoped bare terminal id
    /// (`deviceId == ""`), so legacy/bare keys still resolve.
    /// - Parameter surfaceKey: An encoded surface key (or a bare terminal id).
    public init(surfaceKey: String) {
        guard let separatorIndex = surfaceKey.firstIndex(of: Self.surfaceKeySeparator) else {
            self.init(deviceId: "", terminalID: MobileTerminalPreview.ID(rawValue: surfaceKey))
            return
        }
        let deviceId = String(surfaceKey[surfaceKey.startIndex..<separatorIndex])
        let terminalID = String(surfaceKey[surfaceKey.index(after: separatorIndex)...])
        self.init(deviceId: deviceId, terminalID: MobileTerminalPreview.ID(rawValue: terminalID))
    }
}
