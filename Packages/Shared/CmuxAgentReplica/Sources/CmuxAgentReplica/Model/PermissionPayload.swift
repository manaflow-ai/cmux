import Foundation

/// Carries a permission request emitted by an agent runtime.
public struct PermissionPayload: Codable, Hashable, Sendable {
    /// The tool requesting permission.
    public let toolName: String
    /// The permission detail shown to the user.
    public let detail: String
    /// The available permission choices.
    public let options: [String]

    private enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case detail
        case options
    }

    /// Creates a permission payload.
    /// - Parameters:
    ///   - toolName: The tool requesting permission.
    ///   - detail: The permission detail shown to the user.
    ///   - options: The available permission choices.
    public init(toolName: String, detail: String, options: [String]) {
        self.toolName = toolName
        self.detail = detail
        self.options = options
    }
}
