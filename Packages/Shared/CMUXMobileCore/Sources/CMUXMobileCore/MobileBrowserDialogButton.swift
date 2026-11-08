/// One action offered by a mirrored browser dialog.
public struct MobileBrowserDialogButton: Codable, Equatable, Sendable {
    /// Stable identifier returned in a dialog response.
    public let id: String
    /// Mac-provided button label displayed verbatim on the phone.
    public let label: String
    /// Visual and semantic role of the action.
    public let role: MobileBrowserDialogButtonRole

    /// Creates a mirrored browser dialog action.
    /// - Parameters:
    ///   - id: Stable identifier returned when the action is selected.
    ///   - label: Mac-provided label displayed verbatim.
    ///   - role: Visual and semantic role of the action.
    public init(id: String, label: String, role: MobileBrowserDialogButtonRole) {
        self.id = id
        self.label = label
        self.role = role
    }
}
