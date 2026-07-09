/// Describes one machine-readable reason in a GUI capability report.
///
/// The code is intentionally an open string. `CmuxAgentTruthKit` is macOS-only
/// and maps its capability reasons into this wire-owned value at the boundary.
public struct GuiCapabilityReason: Codable, Hashable, Sendable {
    /// The open machine-readable reason code.
    public let code: String
    /// Optional detail suitable for diagnostics or explanatory UI.
    public let detail: String?

    /// Creates a wire capability reason.
    /// - Parameters:
    ///   - code: The open machine-readable reason code.
    ///   - detail: Optional diagnostic detail.
    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}
