import Foundation

/// How dangerous a scope is. Drives the risk tone (no blue): neutral for
/// `read`, warning for `write` and `network`, danger for `execute` and
/// `external` (first-party-apps.md 5.4).
public nonisolated enum AppScopeRisk: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case read
    case write
    case network
    case execute
    case external

    public var tone: AppRiskTone {
        switch self {
        case .read: .neutral
        case .write, .network: .warning
        case .execute, .external: .danger
        }
    }

    public static func < (lhs: AppScopeRisk, rhs: AppScopeRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The color role of a risk (theme ANSI yellow and red; neutral is text).
public nonisolated enum AppRiskTone: String, Sendable, Hashable, Codable {
    case neutral
    case warning
    case danger
}

/// What an app reaches through a scope (section 5.1 axes). The consent
/// sheet and the permissions pane group scopes by axis.
public nonisolated enum AppScopeAxis: String, Sendable, Hashable, Codable, CaseIterable {
    /// cmux catalog operations (workspaces, terminals, browser, agents).
    case operations
    /// `net:<host>` egress and `integration:<provider>` gateway calls.
    case network
    /// Granted file roots (`fs:*`).
    case files
    /// Commands that run in a visible terminal (`execute` scopes).
    case processes
    /// `mcp:expose`: the app's commands as MCP tools.
    case agents
    case clipboard
    case notifications
    /// `storage:*` (local storage is implicit; synced storage is a scope).
    case storage
}
