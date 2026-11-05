import Foundation

/// The card's look (design section 8). DEV builds switch it in Debug > MCP Connect Card Playground;
/// Lawrence picks one after dogfood. ``factsTable`` is the default.
public enum McpConnectCardStyle: Int, CaseIterable, Sendable {
    /// One line and Connect; the facts behind Details.
    case compactRow = 1
    /// The facts as a two-column table (the recommendation for a verified server).
    case factsTable
    /// A permission sheet: big mark, the access as bullets.
    case permissionSheet
    /// First "X wants to connect" with Review, then the facts and Connect.
    case twoStep
    /// The card is the agent's message bubble with buttons in it.
    case bubble
    /// The risk line leads, in the attention color (the recommendation for unverified and local).
    case dangerForward

    /// The DEV-only playground label.
    public var title: String {
        switch self {
        case .compactRow: "Compact row"
        case .factsTable: "Facts table"
        case .permissionSheet: "Permission sheet"
        case .twoStep: "Two-step"
        case .bubble: "Inline bubble"
        case .dangerForward: "Danger-forward"
        }
    }
}
